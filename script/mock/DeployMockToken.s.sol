// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/mock/mockIDRX.sol";
import "../../src/mock/mockUSDC.sol";

contract DeployMockToken is Script {
    function run() external {
        vm.startBroadcast();

        MockIDRX mockIdrx = new MockIDRX();
        MockUSDC mockUsdc = new MockUSDC();

        console.log("Mock IDRX at: ", address(mockIdrx));
        console.log("Mock USDC at: ", address(mockUsdc));

        vm.stopBroadcast();
    }
}
