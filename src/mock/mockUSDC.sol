// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MockUSDC is ERC20, Ownable {
    uint256 public constant MAX_SUPPLY = type(uint256).max;
    uint256 public constant MINT_LIMIT_PER_REQUEST = 10_000 * 10 ** 6; // 10.00 tokens with 2 decimals

    constructor() ERC20("Mock USDC", "mockUSDC") Ownable(msg.sender) {}

    function decimals() public view virtual override returns (uint8) {
        return 6;
    }

    function mint(uint256 amount) public {
        require(totalSupply() + amount <= MAX_SUPPLY, "Exceeds max supply");
        if (msg.sender != owner()) {
            require(
                amount <= MINT_LIMIT_PER_REQUEST,
                "Exceeds mint limit per request"
            );
        }
        _mint(msg.sender, amount);
    }
}
