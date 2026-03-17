// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/forge-std/src/Script.sol";
import "../src/Nodepad/NodepadDiamondProxy.sol";
import "../src/Nodepad/Facets/AdminFacet.sol";
import "../src/Nodepad/Facets/CoreFacet.sol";
import "../src/Nodepad/Facets/NodeManagementSystem.sol";
import "../src/Nodepad/Facets/ReferralSystemFacet.sol";
import { IERC2535DiamondCut } from "lib/solidstate-solidity/contracts/interfaces/IERC2535DiamondCut.sol";
import { IERC2535DiamondCutInternal } from "lib/solidstate-solidity/contracts/interfaces/IERC2535DiamondCutInternal.sol";
import { IERC2535DiamondLoupe } from "lib/solidstate-solidity/contracts/interfaces/IERC2535DiamondLoupe.sol";

contract DeployNodepad is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0));
        
        if (deployerPrivateKey == 0) {
             vm.startBroadcast();
        } else {
             vm.startBroadcast(deployerPrivateKey);
        }

        // 1. Deploy Diamond Proxy
        NodepadDiamondProxy diamond = new NodepadDiamondProxy();
        console.log("NodepadDiamondProxy deployed at:", address(diamond));

        // 2. Deploy Facets
        AdminFacet adminFacet = new AdminFacet();
        console.log("AdminFacet deployed at:", address(adminFacet));

        CoreFacet coreFacet = new CoreFacet();
        console.log("CoreFacet deployed at:", address(coreFacet));

        NodeManagementSystem nodeManagementFacet = new NodeManagementSystem();
        console.log("NodeManagementSystem deployed at:", address(nodeManagementFacet));

        ReferralSystemFacet referralSystemFacet = new ReferralSystemFacet();
        console.log("ReferralSystemFacet deployed at:", address(referralSystemFacet));

        // 3. Prepare Facet Cuts
        IERC2535DiamondCut.FacetCut[] memory cuts = new IERC2535DiamondCut.FacetCut[](4);

        // AdminFacet
        cuts[0] = IERC2535DiamondCutInternal.FacetCut({
            target: address(adminFacet),
            action: IERC2535DiamondCutInternal.FacetCutAction.ADD,
            selectors: getSelectors(address(adminFacet), address(diamond))
        });

        // CoreFacet
        cuts[1] = IERC2535DiamondCutInternal.FacetCut({
            target: address(coreFacet),
            action: IERC2535DiamondCutInternal.FacetCutAction.ADD,
            selectors: getSelectors(address(coreFacet), address(diamond))
        });

        // NodeManagementSystem
        cuts[2] = IERC2535DiamondCutInternal.FacetCut({
            target: address(nodeManagementFacet),
            action: IERC2535DiamondCutInternal.FacetCutAction.ADD,
            selectors: getSelectors(address(nodeManagementFacet), address(diamond))
        });

        // ReferralSystemFacet
        cuts[3] = IERC2535DiamondCutInternal.FacetCut({
            target: address(referralSystemFacet),
            action: IERC2535DiamondCutInternal.FacetCutAction.ADD,
            selectors: getSelectors(address(referralSystemFacet), address(diamond))
        });

        // 4. Add Facets to Diamond
        IERC2535DiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
        console.log("Facets added to Diamond");

        // 5. Initialize
        // We cast the diamond address to AdminFacet to call initialize
        // Note: Ensure AdminFacet has the initialize function selector added.
        AdminFacet(address(diamond)).initialize("INIT_CODE_2024");
        console.log("Nodepad initialized");

        vm.stopBroadcast();
    }

    function getSelectors(address facet, address diamond) internal view returns (bytes4[] memory selectors) {
        bytes4[] memory allSelectors = vm.getAllFunctions(facet);
        
        // Count valid selectors (not already in diamond)
        uint256 count = 0;
        for (uint256 i = 0; i < allSelectors.length; i++) {
            if (IERC2535DiamondLoupe(diamond).facetAddress(allSelectors[i]) == address(0)) {
                count++;
            }
        }

        selectors = new bytes4[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < allSelectors.length; i++) {
            if (IERC2535DiamondLoupe(diamond).facetAddress(allSelectors[i]) == address(0)) {
                selectors[index] = allSelectors[i];
                index++;
            }
        }
    }
}
