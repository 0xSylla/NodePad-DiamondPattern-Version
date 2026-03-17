//SPDX-License-Identifier:MIT
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

library PriceConverter{
    function getPrice() public view returns (uint256){
       AggregatorV3Interface dataFeed = AggregatorV3Interface(0x694AA1769357215DE4FAC081bf1f309aDC325306);
        (
            /* uint80 roundId */,
            int256 answer,
            /*uint256 startedAt*/,
            /*uint256 updatedAt*/,
            /*uint80 answeredInRound*/
        ) = dataFeed.latestRoundData();
        return uint256(answer*1e10);
    }

    function ethToUsd(uint256 _ethAmount) public view returns (uint256){
        uint ethPrice = getPrice();
        uint ethToUsdAmount = (_ethAmount * ethPrice)/1e18;
        return ethToUsdAmount;
    }

    function usdToEth(uint256 _usdAmount) public view returns (uint256){
        uint ethPrice = getPrice();
        uint usdToEthAmount = (_usdAmount * 1e18) / ethPrice;
        return usdToEthAmount;
    }
}
