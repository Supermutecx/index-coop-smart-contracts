/*
    Copyright 2021 Set Labs Inc.
    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at
    http://www.apache.org/licenses/LICENSE-2.0
    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
*/

pragma solidity 0.6.10;
pragma experimental ABIEncoderV2;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/SafeCast.sol";
import { SafeMath } from "@openzeppelin/contracts/math/SafeMath.sol";

import { BaseAdapter } from "../lib/BaseAdapter.sol";
import { IAirdropModule } from "../interfaces/IAirdropModule.sol";
import { IBaseManager } from "../interfaces/IBaseManager.sol";
import { ISetToken } from "../interfaces/ISetToken.sol";
import { PreciseUnitMath } from "../lib/PreciseUnitMath.sol";

/**
 * @title COMPReinvestmentExtension
 * @author bronco.eth
 *
 * If a SetToken receives COMP tokens as rewards from depositing assets in the Compound protocol, this adapter enables claiming and trading 
 * accumulated COMP for one specified target cToken asset.
 * 
 * Implementation spec: https://docs.google.com/document/d/1_ZAj50JaimkvoOUGfOb60o2hTKLigsnTC_JknOqTdVk/edit#
 */
contract COMPReinvestmentExtension is BaseAdapter {
    using Address for address;
    using PreciseUnitMath for uint256;
    using SafeCast for int256;
    using SafeMath for uint256;

    /* ============ Structs ============ */

    struct ReapSettings {
        address claimModule;        // Address of the Set V2 ClaimModule to claim COMP from the Comptroller
        string claimAdapterName;    // String used to identify the CompClaimAdapter in the IntegrationRegistry
        address airdropModule;      // Address of the Set V2 AirdropModule to absorb COMP into a position
        address wrapModule;         // Address of the Set V2 WrapModule to mint collateral cToken
        string wrapAdapterName;     // String used to identify the CompoundWrapAdapter in the IntegrationRegistry
        address tradeModule;        // Address of the Set V2 TradeModule to trade COMP for collateral cToken
        string exchangeAdapterName; // String used to identify the exchange adapter in the IntegrationRegistry
        bytes exchangeData;         // Arbitrary exchange data passed into trade() function to exchange COMP
    }

    /* ============ Events ============ */

    event COMPReaped(
        uint256 _compAbsorbed,
        uint256 _collateralReceived,
        address _caller
    );

    event ReapSettingsUpdated(
        address _claimModule,
        string _claimAdapterName,
        address _airdropModule,
        address _wrapModule,
        string _wrapAdapterName,
        address _tradeModule,
        string _exchangeAdapterName,
        bytes _exchangeData
    );

    event ExchangeDataUpdated(
        bytes _oldExchangeData,
        bytes _newExchangeData
    );

    /* ============ State Variables ============ */

    ISetToken public setToken;

    // Address of the target collateral underlying asset. Must match the underlying in the collateral cToken
    address public collateralAsset;
    // Address of the target collateral cToken to transform accumulated COMP into
    address public collateralCToken;
    // Address of the Compound Comptroller
    address public comptroller;
    // Address of the COMP token
    address public compToken;
    // Struct containing Set Protocol module and adapter parameters used in reap function
    ReapSettings public reapSettings;
    // Address of Compound cEther
    address public cEther;

    /* ============ Constructor ============ */

    /**
     * Instantiate state of the reinvestment adapter
     * 
     * @param _manager                  Address of IBaseManager contract, owner of the FLI contract
     * @param _collateralAsset          Address of the collateral asset
     * @param _collateralCToken         Address of compound wrapped token of the collateral asset
     * @param _comptroller              Address of the comptroller proxy contract
     * @param _compToken                Address of the COMP token
     * @param _reapSettings             Struct containing Set Protocol module and adapter parameters used in reap function
     */
    constructor(
        IBaseManager _manager,
        address _collateralAsset,
        address _collateralCToken,
        address _comptroller,
        address _compToken,
        address _cEther,
        ReapSettings memory _reapSettings
    )
        public
        BaseAdapter(_manager)
    {
        setToken = manager.setToken();
        collateralAsset = _collateralAsset;
        collateralCToken = _collateralCToken;
        comptroller = _comptroller;
        compToken = _compToken;
        cEther = _cEther;
        reapSettings = _reapSettings;
    }

    /* ============ External Functions ============ */

    /**
     * ONLY EOA: Use accrued COMP to increase a cToken collateral position in a SetToken. All COMP claimed in the reap flow will be traded and 
     * wrapped into cTokens, so there will be no additional COMP or underlying collateral positions added. Existing COMP or underlying collateral
     * positions in the SetToken are not affected by this flow.
     * 
     * Reap:
     *   Claim COMP via ClaimModule
     *   Absorb COMP / collect fees via AirdropModule
     *   Trade COMP for collateral asset via TradeModule. Skip trade if collateral asset is COMP
     *   Wrap to cToken via WrapModule
     */
     function reap() external onlyEOA {
        _claim();

        uint256 compUnitsToTrade = _absorb();

        uint256 collateralUnitsToWrap;
        // In cases where there are no COMP to trade, then skip trade and wrap. One scenario is if the manager chooses an 100% absorb fee.
        if (compUnitsToTrade > 0) {
            collateralUnitsToWrap = _trade(compUnitsToTrade);

            _wrap(collateralUnitsToWrap);
        }

        emit COMPReaped(compUnitsToTrade, collateralUnitsToWrap, msg.sender);
    }

    /**
     * OPERATOR ONLY: Set modules and adapters used in reap function. Note: Need to pass in existing parameters if only changing a few
     * settings. An invalid configuration will cause reap to revert, which is a low risk function that does not affect existing user
     * funds.
     *
     * @param _reapSettings   Struct containing new module parameters
     */
    function setReapSettings(ReapSettings memory _reapSettings) external onlyOperator {
        reapSettings = _reapSettings;

        emit ReapSettingsUpdated(
            reapSettings.claimModule,
            reapSettings.claimAdapterName,
            reapSettings.airdropModule,
            reapSettings.wrapModule,
            reapSettings.wrapAdapterName,
            reapSettings.tradeModule,
            reapSettings.exchangeAdapterName,
            reapSettings.exchangeData
        );
    }

    function updateAirdropFeeRecipient(address _newFeeRecipient) external onlyOperator {
        bytes memory callData = abi.encodeWithSignature("updateFeeRecipient(address,address)", address(setToken), _newFeeRecipient);
        invokeManager(reapSettings.airdropModule, callData);
    }

    function updateAirdropFee(uint256 _newAirdropFee) external onlyOperator {
        bytes memory callData = abi.encodeWithSignature("updateAirdropFee(address,uint256)", address(setToken), _newAirdropFee);
        invokeManager(reapSettings.airdropModule, callData);
    }

    function initializeModules(uint256 _airdropFee) external onlyOperator {
        _initializeClaimModule();

        _initializeAirdropModule(_airdropFee);

        _initializeWrapAndTradeModule();
    }

    /* ============ Internal Functions ============ */

    function _claim() internal {       
        bytes memory claimCallData = abi.encodeWithSignature(
            "claim(address,address,string)",
            address(setToken),
            comptroller,
            reapSettings.claimAdapterName
        );
       
        invokeManager(reapSettings.claimModule, claimCallData);
    }

    function _absorb() internal returns(uint256) {
        uint256 preAbsorbCompUnits = setToken.getDefaultPositionRealUnit(compToken).toUint256();

        bytes memory absorbCallData = abi.encodeWithSignature(
            "absorb(address,address)",
            address(setToken),
            compToken
        );

        invokeManager(reapSettings.airdropModule, absorbCallData);

        uint256 postAbsorbCompUnits = setToken.getDefaultPositionRealUnit(compToken).toUint256();
        return postAbsorbCompUnits.sub(preAbsorbCompUnits);
    }

    function _trade(uint256 _compUnitsToTrade) internal returns(uint256) {
        uint256 collateralUnitsToWrap;

        // If collateral asset is not the same as COMP, then execute trade. Otherwise skip trade and return COMP units to wrap
        if (collateralAsset != compToken) {
            uint256 preTradeCollateralUnits = setToken.getDefaultPositionRealUnit(collateralAsset).toUint256();
            bytes memory tradeCallData = abi.encodeWithSignature(
                "trade(address,string,address,uint256,address,uint256,bytes)",
                address(setToken),
                reapSettings.exchangeAdapterName,
                compToken,
                _compUnitsToTrade,
                collateralAsset,
                0, // Set min receive amount to 0 as trades sizes are typically very small
                reapSettings.exchangeData
            );
            invokeManager(reapSettings.tradeModule, tradeCallData);

            collateralUnitsToWrap = setToken.getDefaultPositionRealUnit(collateralAsset).toUint256().sub(preTradeCollateralUnits);
        } else {
            collateralUnitsToWrap = _compUnitsToTrade;
        }

        return collateralUnitsToWrap;
    }

    function _wrap(uint256 _collateralUnitsToWrap) internal {
        bytes memory wrapCallData;

        uint256 preWrapCollateralUnits = setToken.getDefaultPositionRealUnit(collateralAsset).toUint256();

        if (collateralCToken == cEther) {
            wrapCallData = abi.encodeWithSignature(
                "wrapWithEther(address,address,uint256,string)",
                address(setToken),
                collateralCToken,
                _collateralUnitsToWrap,
                reapSettings.wrapAdapterName
            );
        } else {
            wrapCallData = abi.encodeWithSignature(
                "wrap(address,address,address,uint256,string)",
                address(setToken),
                collateralCToken,
                collateralAsset,
                _collateralUnitsToWrap,
                reapSettings.wrapAdapterName
            );
        }

        invokeManager(reapSettings.wrapModule, wrapCallData);

        uint256 postWrapCollateralUnits = setToken.getDefaultPositionRealUnit(collateralAsset).toUint256();
        // Compound does not revert on errors, so we must ensure here that the minted units are subtracted after wrap
        require(postWrapCollateralUnits.add(_collateralUnitsToWrap) == preWrapCollateralUnits, "Wrap failed on Compound");
    }

    function _initializeClaimModule() internal {
        address[] memory rewardPools = new address[](1);
        rewardPools[0] = comptroller;
        string[] memory claimIntegrationNames = new string[](1);
        claimIntegrationNames[0] = reapSettings.claimAdapterName;
        bytes memory claimModuleCalldata = abi.encodeWithSignature(
            "initialize(address,bool,address[],string[])",
            address(setToken),
            false,
            rewardPools,
            claimIntegrationNames
        );

        invokeManager(address(reapSettings.claimModule), claimModuleCalldata);
    }

    function _initializeAirdropModule(uint256 _airdropFee) internal {
        address[] memory airdrops = new address[](1);
        airdrops[0] = compToken;
        IAirdropModule.AirdropSettings memory airdropSettings = IAirdropModule.AirdropSettings({
            airdrops: airdrops,
            feeRecipient: address(manager),
            airdropFee: _airdropFee,
            anyoneAbsorb: false // Must be false to ensure there is no unintended COMP added to the SetToken position (e.g. in FLI)
        });

        bytes memory airdropModuleCalldata = abi.encodeWithSignature(
            "initialize(address,(address[],address,uint256,bool))",
            address(setToken),
            airdropSettings
        );

        invokeManager(reapSettings.airdropModule, airdropModuleCalldata);
    }

    function _initializeWrapAndTradeModule() internal {
        bytes memory callData = abi.encodeWithSignature(
            "initialize(address)",
            address(setToken)
        );

        invokeManager(reapSettings.wrapModule, callData);
        invokeManager(reapSettings.tradeModule, callData);
    }
}