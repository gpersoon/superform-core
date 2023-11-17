// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.21;

import { AbstractNewPaymentHelper } from "./Abstract.NewPaymentHelper.s.sol";

contract NewPaymentHelper is AbstractNewPaymentHelper {
    /*//////////////////////////////////////////////////////////////
                        SELECT CHAIN IDS TO DEPLOY HERE
    //////////////////////////////////////////////////////////////*/

    uint64[] TARGET_DEPLOYMENT_CHAINS = [BSC, POLY, AVAX];

    function newPaymentHelper(uint256 selectedChainIndex) external {
        uint256 trueIndex;
        for (uint256 i = 0; i < chainIds.length; i++) {
            if (TARGET_DEPLOYMENT_CHAINS[selectedChainIndex] == chainIds[i]) {
                trueIndex = i;
                break;
            }
        }

        _newPaymentHelper(selectedChainIndex, trueIndex, Cycle.Prod, TARGET_DEPLOYMENT_CHAINS, TARGET_DEPLOYMENT_CHAINS);
    }
}
