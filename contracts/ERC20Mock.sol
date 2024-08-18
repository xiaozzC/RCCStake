// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// 模拟 ERC20 代币合约，用于测试
contract ERC20Mock is ERC20 {
    uint8 private _mockDecimals;

    // 构造函数
    constructor(
        string memory name, 
        string memory symbol, 
        uint8 decimals, 
        uint256 initialSupply
    ) 
        ERC20(name, symbol) 
    {
        _mockDecimals = decimals;
        // 直接调用 ERC20 的构造函数来设置名字和符号
        // 使用 _mint 函数铸造初始供应量
        _mint(msg.sender, initialSupply);
    }

    // 重写 decimals 函数
    function decimals() public view virtual override returns (uint8) {
        return _mockDecimals;
    }
}
