// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title TokenFactory
 * @notice CREATE2 工厂合约，用于部署带自定义尾号的代币合约
 */
contract TokenFactory {
    address public owner;
    address[] public deployedTokens;
    mapping(address => bool) public isDeployed;

    event TokenDeployed(address indexed token, bytes32 salt, address indexed deployer);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    /**
     * @notice 使用 CREATE2 部署代币合约
     * @param salt 盐值（用于碰撞目标地址）
     * @param initCode 合约字节码 + ABI 编码的构造函数参数
     * @return token 部署后的合约地址
     */
    function deploy(bytes32 salt, bytes memory initCode) external returns (address token) {
        assembly {
            token := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        require(token != address(0), "Deploy failed");
        deployedTokens.push(token);
        isDeployed[token] = true;
        emit TokenDeployed(token, salt, msg.sender);
    }

    function getDeployedCount() external view returns (uint256) {
        return deployedTokens.length;
    }

    function getDeployedToken(uint256 index) external view returns (address) {
        require(index < deployedTokens.length, "Index OOB");
        return deployedTokens[index];
    }

    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
    }
}
