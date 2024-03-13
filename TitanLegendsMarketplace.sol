// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/interfaces/IERC721.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract TitanLegendsMarketplace is ERC721Holder, ReentrancyGuard, Ownable2Step {
    struct Listing {
        uint256 tokenId;
        uint256 price;
        address owner;
    }

    using EnumerableSet for EnumerableSet.UintSet;

    uint256 public currentListingId;
    uint64 public marketplaceFee;
    address private feeStorage;
    IERC721 public immutable titanLegends;
    IERC20 public immutable titanX;

    mapping(uint256 => Listing) public listings;
    EnumerableSet.UintSet private activeListings;

    event ListingAdded(uint256 indexed listingId, uint256 indexed tokenId, address indexed owner, uint256 price);
    event ListingRemoved(uint256 indexed listingId);
    event ListingEdited(uint256 indexed listingId, uint256 price);
    event ListingSold(uint256 indexed listingId, address buyer);

    constructor(address nftAddress, address tokenAddress, address feeStorageAddress) Ownable(msg.sender) {
        titanLegends = IERC721(nftAddress);
        titanX = IERC20(tokenAddress);
        marketplaceFee = 300;
        feeStorage = feeStorageAddress;
    }

    function addListing(uint256 tokenId, uint256 price) external {
        require(price > 0, "Price must be greater than zero");
        uint256 listingId = currentListingId;
        titanLegends.safeTransferFrom(msg.sender, address(this), tokenId);

        listings[listingId] = Listing(tokenId, price, msg.sender);
        activeListings.add(listingId);
        currentListingId++;
        emit ListingAdded(listingId, tokenId, msg.sender, price);
    }

    function buyListing(uint256 listingId, uint256 price) external nonReentrant {
        require(isListingActive(listingId), "Listing is not active");
        Listing memory listing = listings[listingId];
        require(listing.price == price, "Incorrect price provided");
        uint256 _marketplaceFee = (listing.price * marketplaceFee) / 10000;
        activeListings.remove(listingId);
        delete listings[listingId];

        titanX.transferFrom(msg.sender, feeStorage, _marketplaceFee);
        titanX.transferFrom(msg.sender, listing.owner, listing.price - _marketplaceFee);
        titanLegends.safeTransferFrom(address(this), msg.sender, listing.tokenId);
        emit ListingSold(listingId, msg.sender);
    }

    function removeListing(uint256 listingId) external nonReentrant {
        require(isListingActive(listingId), "Listing is not active");
        Listing memory listing = listings[listingId];
        require(listing.owner == msg.sender, "Not authorized");
        activeListings.remove(listingId);
        delete listings[listingId];

        titanLegends.safeTransferFrom(address(this), msg.sender, listing.tokenId);
        emit ListingRemoved(listingId);
    }

    function editListing(uint256 listingId, uint256 newPrice) external {
        require(isListingActive(listingId), "Listing is not active");
        Listing storage listing = listings[listingId];
        require(listing.owner == msg.sender, "Not authorized");
        require(newPrice > 0, "Price need to be higher than 0");

        listing.price = newPrice;
        emit ListingEdited(listingId, newPrice);
    }

    function getActiveListings() external view returns (uint256[] memory) {
        return activeListings.values();
    }

    function isListingActive(uint256 listingId) public view returns (bool) {
        return activeListings.contains(listingId);
    }

    function setMarketplaceFee(uint64 fee) external onlyOwner {
        require(fee <= 800, "Marketplace fee should not exceed 8 percent");
        require(fee > 0, "Marketplace fee should be greater than zero");
        marketplaceFee = fee;
    }

    function setFeeStorage(address storageAdr) external onlyOwner {
        require(storageAdr != address(0), "Fee storage cannot be a zero address");
        feeStorage = storageAdr;
    }
}

