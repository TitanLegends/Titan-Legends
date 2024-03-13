// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/interfaces/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./ILGNDX.sol";

contract TitanLegendsBattlefield is ERC721Holder, ReentrancyGuard, Ownable2Step {
    using EnumerableSet for EnumerableSet.UintSet;

    IERC721 public immutable titanLegends;
    ILGNDX public immutable legendX;

    uint256 public constant tokensPerBountyPoint = 59_644.655 ether;
    uint64 public maxPerBounty = 8;
    uint64 public bountyCooldown = 8 days;
    mapping(address => EnumerableSet.UintSet) private _battles;
    mapping(address => uint256) public battleEntered;

    event BountyClaimed(address addr, uint256[] tokenIds);
    event RansomPaid(address addr, uint256[] tokenIds);

    constructor(address _titanLegends, address _legendX) Ownable(msg.sender) {
        titanLegends = IERC721(_titanLegends);
        legendX = ILGNDX(_legendX);
    }

    function dragonsAtBattle(address account) external view returns (uint256[] memory) {
        return _battles[account].values();
    }

    function bountyAvailable(address account) public view returns (bool) {
        return block.timestamp - battleEntered[account] > bountyCooldown;
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

    function claimBounty(uint256[] calldata tokenIds) external nonReentrant {
        require(bountyAvailable(msg.sender), "You cannot claim bounty now");
        require(tokenIds.length <= maxPerBounty, "Max number of dragons per bounty exceeded");
        uint256 multiplierPool;
        for (uint256 i; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            unchecked {
                multiplierPool += getMultiplier(tokenId);
            }
            titanLegends.safeTransferFrom(msg.sender, address(this), tokenId);
            _battles[msg.sender].add(tokenId);
        }
        uint256 bountyPool = multiplierPool * tokensPerBountyPoint;
        uint256 burnPool = (bountyPool * 3) / 100;
        legendX.burn(burnPool);
        legendX.transfer(msg.sender, bountyPool - burnPool);
        battleEntered[msg.sender] = block.timestamp;
        emit BountyClaimed(msg.sender, tokenIds);
    }

    function payRansom(uint256[] calldata tokenIds) external nonReentrant {
        uint256 multiplierPool;
        for (uint256 i; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            require(_battles[msg.sender].contains(tokenId), "You are not the original owner");
            unchecked {
                multiplierPool += getMultiplier(tokenId);
            }
            titanLegends.safeTransferFrom(address(this), msg.sender, tokenId);
            _battles[msg.sender].remove(tokenId);
        }
        uint256 ransomPool = multiplierPool * tokensPerBountyPoint;
        uint256 burnPool = (ransomPool * 3) / 100;
        legendX.transferFrom(msg.sender, address(this), ransomPool + burnPool);
        legendX.burn(burnPool);
        emit RansomPaid(msg.sender, tokenIds);
    }

    function setMaxPerBounty(uint64 _limit) external onlyOwner {
        maxPerBounty = _limit;
    }

    function setBountyCooldown(uint64 _limit) external onlyOwner {
        bountyCooldown = _limit;
    }
}

