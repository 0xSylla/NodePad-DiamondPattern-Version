//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

//Total supply 69 Millions. 
//A pair is automatically set up at creation
//Pause resume trading 
//Token have a buy/sell tax whale for the first 24hour to prevent snipers and reduce selling pressure. 
//Whale tax for preventing dumping and protect diamond hands 
contract GameToken is ERC20, Ownable{
    constructor() ERC20("GAME", "GAME") Ownable(msg.sender) {
        _mint(msg.sender, 69_000_000 * 10**18); // 69M supply (fixed per your comment)
    }
    
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
    
    function burnFrom(address account, uint256 amount) external {
        uint256 currentAllowance = allowance(account, msg.sender);
        require(currentAllowance >= amount, "Burn amount exceeds allowance");
        _approve(account, msg.sender, currentAllowance - amount);
        _burn(account, amount);
    }
}

contract paymentToken is ERC20, Ownable{
    constructor() ERC20("USDC", "USDC") Ownable(msg.sender) {
        _mint(msg.sender, 10_000_000 * 10**18); // 69M supply (fixed per your comment)
    }
    
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
    
    function burnFrom(address account, uint256 amount) external {
        uint256 currentAllowance = allowance(account, msg.sender);
        require(currentAllowance >= amount, "Burn amount exceeds allowance");
        _approve(account, msg.sender, currentAllowance - amount);
        _burn(account, amount);
    }
}

contract RewardToken is ERC20, Ownable{
    constructor() ERC20("Reward", "REWARD") Ownable(msg.sender) {
        _mint(msg.sender, 10_000_000 * 10**18); // 69M supply (fixed per your comment)
    }
    
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
    
    function burnFrom(address account, uint256 amount) external {
        uint256 currentAllowance = allowance(account, msg.sender);
        require(currentAllowance >= amount, "Burn amount exceeds allowance");
        _approve(account, msg.sender, currentAllowance - amount);
        _burn(account, amount);
    }
}