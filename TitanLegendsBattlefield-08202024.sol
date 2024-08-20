// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/interfaces/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "./ILGNDX.sol";
import "./ITitanLegendsMarketplace.sol";

contract TitanLegendsBattlefield is ERC721Holder, ReentrancyGuard, Ownable2Step {
    using EnumerableSet for EnumerableSet.UintSet;

    IERC721 public immutable titanLegends;
    IERC20 public immutable titanX;
    ITitanLegendsMarketplace public immutable marketplace;
    ILGNDX public legendX;

    uint256 public constant tokensPerBountyPoint = 59_954.112 ether;
    uint256 public activationTime;
    uint64 public maxPerBounty = 25;
    bool public tokenSet;
    bool public active;
    bool public marketplaceExclusionEnabled;

    EnumerableSet.UintSet private battle;
    mapping(uint256 tokenId => bool) public isExcluded;

    event BountyClaimed(address addr, uint256[] tokenIds);
    event RansomPaid(address addr, uint256[] tokenIds);

    constructor(address _titanLegends, address _titanX, address _marketplace) Ownable(msg.sender) {
        titanLegends = IERC721(_titanLegends);
        titanX = IERC20(_titanX);
        marketplace = ITitanLegendsMarketplace(_marketplace);
    }

    function dragonsAtBattle() external view returns (uint256[] memory) {
        return battle.values();
    }

    function getEarlyClaimBurn() public view returns (uint256) {
        uint256 daysPassed = (block.timestamp - activationTime) / 86400;
        if (daysPassed > 24) return 0;
        return 50 - daysPassed * 2;
    }

    function getMultiplier(uint256 tokenId) public pure returns (uint256) {
        if (
            tokenId == 46 || tokenId == 135 || tokenId == 212 || tokenId == 225 || tokenId == 427 || tokenId == 532
                || tokenId == 591 || tokenId == 694 || tokenId == 735 || tokenId == 811 || tokenId == 946 || tokenId == 1139
                || tokenId == 1210 || tokenId == 1237 || tokenId == 1357 || tokenId == 1457 || tokenId == 1503
                || tokenId == 1561 || tokenId == 1663 || tokenId == 1876 || tokenId == 1996 || tokenId == 2089
                || tokenId == 2251
        ) return 80;
        if (tokenId > 1500) return 28;
        return 10;
    }

    function processBountyNfts(uint256[] memory tokenIds) private returns (uint256 totalBounty, uint256 burnPool) {
        uint256 earlyClaimBurn = getEarlyClaimBurn();
        if (earlyClaimBurn > 0) {
            uint256 multiplierPool;
            for (uint256 i; i < tokenIds.length; i++) {
                uint256 tokenId = tokenIds[i];
                uint256 burnPercent = isExcluded[tokenId] ? 3 : earlyClaimBurn + 3;
                unchecked {
                    uint256 multiplier = getMultiplier(tokenId);
                    multiplierPool += multiplier;
                    burnPool += (multiplier * burnPercent * tokensPerBountyPoint) / 100;
                }
                titanLegends.safeTransferFrom(msg.sender, address(this), tokenId);
                battle.add(tokenId);
            }
            totalBounty = multiplierPool * tokensPerBountyPoint;
        } else {
            uint256 multiplierPool;
            for (uint256 i; i < tokenIds.length; i++) {
                uint256 tokenId = tokenIds[i];
                unchecked {
                    multiplierPool += getMultiplier(tokenId);
                }
                titanLegends.safeTransferFrom(msg.sender, address(this), tokenId);
                battle.add(tokenId);
            }
            totalBounty = multiplierPool * tokensPerBountyPoint;
            burnPool = (totalBounty * 3) / 100;
        }
        return (totalBounty, burnPool);
    }

    function claimBounty(uint256[] calldata tokenIds) external nonReentrant {
        require(active, "The Battlefield is not active");
        require(tokenIds.length <= maxPerBounty, "Max number of dragons per bounty exceeded");
        (uint256 totalBounty, uint256 burnPool) = processBountyNfts(tokenIds);
        legendX.burn(burnPool);
        legendX.transfer(msg.sender, totalBounty - burnPool);
        emit BountyClaimed(msg.sender, tokenIds);
    }

    function payRansom(uint256[] calldata tokenIds) external nonReentrant {
        require(active, "The Battlefield is not active");
        uint256 multiplierPool;
        bool isGracePeriod = getEarlyClaimBurn() > 0;
        for (uint256 i; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            unchecked {
                multiplierPool += getMultiplier(tokenId);
            }
            titanLegends.safeTransferFrom(address(this), msg.sender, tokenId);
            if (isGracePeriod) isExcluded[tokenId] = true;
            battle.remove(tokenId);
        }
        uint256 ransomPool = multiplierPool * tokensPerBountyPoint;
        uint256 burnPool = (ransomPool * 3) / 100;
        legendX.transferFrom(msg.sender, address(this), ransomPool + burnPool);
        legendX.burn(burnPool);
        emit RansomPaid(msg.sender, tokenIds);
    }

    function purchaseListingFromMarketplace(uint256 listingId, uint256 price) external nonReentrant {
        require(getEarlyClaimBurn() > 0, "Only available during grace period");
        require(marketplaceExclusionEnabled, "Function disabled");
        titanX.transferFrom(msg.sender, address(this), price);
        titanX.approve(address(marketplace), price);
        (uint256 tokenId,,) = marketplace.listings(listingId);
        marketplace.buyListing(listingId, price);
        isExcluded[tokenId] = true;
        titanLegends.safeTransferFrom(address(this), msg.sender, tokenId);
    }

    function setMaxPerBounty(uint64 _limit) external onlyOwner {
        maxPerBounty = _limit;
    }

    function addExemption(uint256[] calldata tokenIds) external onlyOwner {
        for (uint256 i; i < tokenIds.length; i++) {
            isExcluded[tokenIds[i]] = true;
        }
    }

    function setToken(address tokenAddress) external onlyOwner {
        require(!tokenSet, "Can only be done once");
        legendX = ILGNDX(tokenAddress);
        tokenSet = true;
    }

    function setMarketplaceExclusion(bool isEnabled) external onlyOwner {
        marketplaceExclusionEnabled = isEnabled;
    }

    function activateBattlefield() external onlyOwner {
        require(tokenSet, "Token is not set");
        require(!active, "Battlefield is already active");
        active = true;
        marketplaceExclusionEnabled = true;
        activationTime = block.timestamp;
    }
}
