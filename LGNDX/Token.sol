/*
Titan Legends / $LGNDX
NFT // TOKEN HYBRID

Titan Legends revolutionizes the NFT landscape, merging NFTs and an ERC-20 token into one cohesive ecosystem. 

Our innovative two-way escrow mechanism seamlessly integrates the NFT and token markets, creating a deflationary NFT with unique game theory dynamics. 

By tackling the NFT liquidity issue head-on, we've pioneered a solution that sets us apart in the crypto space. 

We're not just innovating DeFi on TitanX; we're defining NFTs 2.0...

Official Website: https://www.titanlegends.win/
Official Twitter: https://twitter.com/titanlegends888
Official Telegram: https://t.me/titanlegends
*/


// SPDX-License-Identifier: No License
pragma solidity 0.8.19;

import "./ERC20.sol";
import "./ERC20Burnable.sol";
import "./Ownable2Step.sol";

contract LegendX is ERC20, ERC20Burnable, Ownable2Step {
    
    mapping (address => bool) public isExcludedFromLimits;

    uint256 public maxWalletAmount;
 
    event ExcludeFromLimits(address indexed account, bool isExcluded);

    event MaxWalletAmountUpdated(uint256 maxWalletAmount);
 
    constructor()
        ERC20(unicode"LegendX", unicode"LGNDX") 
    {
        address supplyRecipient = 0xF279986D7ac76bEE90C55928536867981C400319;
        
        _excludeFromLimits(supplyRecipient, true);
        _excludeFromLimits(address(this), true);
        _excludeFromLimits(address(0), true); 

        updateMaxWalletAmount(28888888880 * (10 ** decimals()) / 10);

        _mint(supplyRecipient, 28888888880 * (10 ** decimals()) / 10);
        _transferOwnership(0xF279986D7ac76bEE90C55928536867981C400319);
    }
    
    receive() external payable {}

    function decimals() public pure override returns (uint8) {
        return 18;
    }
    
    function excludeFromLimits(address account, bool isExcluded) external onlyOwner {
        _excludeFromLimits(account, isExcluded);
    }

    function _excludeFromLimits(address account, bool isExcluded) internal {
        isExcludedFromLimits[account] = isExcluded;

        emit ExcludeFromLimits(account, isExcluded);
    }

    function updateMaxWalletAmount(uint256 _maxWalletAmount) public onlyOwner {
        require(_maxWalletAmount >= _maxWalletSafeLimit(), "MaxWallet: Limit too low");
        maxWalletAmount = _maxWalletAmount;
        
        emit MaxWalletAmountUpdated(_maxWalletAmount);
    }

    function _maxWalletSafeLimit() private view returns (uint256) {
        return totalSupply() / 1000;
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount)
        internal
        override
    {
        super._beforeTokenTransfer(from, to, amount);
    }

    function _afterTokenTransfer(address from, address to, uint256 amount)
        internal
        override
    {
        if (!isExcludedFromLimits[to]) {
            require(balanceOf(to) <= maxWalletAmount, "MaxWallet: Cannot exceed max wallet limit");
        }

        super._afterTokenTransfer(from, to, amount);
    }
}