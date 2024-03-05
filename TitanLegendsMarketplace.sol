// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "erc721a/contracts/IERC721A.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract TitanLegendsMarketplace is ERC721Holder, ReentrancyGuard, Ownable {
    struct Listing {
        uint256 tokenId;
        uint256 price;
        address owner;
    }

    using EnumerableSet for EnumerableSet.UintSet;

    uint256 public currentListingId;

    uint64 public marketplaceFee;

    address private feeStorage;
    IERC721A public titanLegends;
    IERC20 public titanX;

    mapping(uint256 => Listing) public listings;
    EnumerableSet.UintSet private activeListings;

    event ListingAdded(
        uint256 indexed listingId,
        uint256 indexed tokenId,
        address indexed owner,
        uint256 price
    );

    event ListingRemoved(uint256 indexed listingId);
    event ListingEdited(uint256 indexed listingId, uint256 price);
    event ListingSold(uint256 indexed listingId, address buyer);

    constructor(
        address nftAddress,
        address tokenAddress,
        address feeStorageAddress
    ) Ownable(msg.sender) {
        titanLegends = IERC721A(nftAddress);
        titanX = IERC20(tokenAddress);
        marketplaceFee = 300;
        feeStorage = feeStorageAddress;
    }

    function addListing(uint256 tokenId, uint256 price) public nonReentrant {
        require(tx.origin == _msgSender(), "Contracts are prohibited");
        require(price > 0, "Price must be greater than zero");
        require(!isListingActive(currentListingId), "Listing already active");
        uint256 listingId = currentListingId;
        titanLegends.safeTransferFrom(msg.sender, address(this), tokenId);
        listings[listingId] = Listing(tokenId, price, msg.sender);

        activeListings.add(listingId);
        currentListingId++;
        emit ListingAdded(listingId, tokenId, msg.sender, price);
    }

    function buyListing(
        uint256 listingId,
        uint256 price
    ) public payable nonReentrant {
        require(tx.origin == _msgSender(), "Contracts are prohibited");
        require(isListingActive(listingId), "Listing is not active");
        Listing memory listing = listings[listingId];
        require(listing.price == price, "Incorrect price provided");
        uint256 _marketplaceFee = (listing.price * marketplaceFee) / 10000;
        titanX.transferFrom(msg.sender, feeStorage, _marketplaceFee);
        titanX.transferFrom(
            msg.sender,
            listing.owner,
            listing.price - _marketplaceFee
        );
        titanLegends.safeTransferFrom(
            address(this),
            msg.sender,
            listing.tokenId
        );

        activeListings.remove(listingId);
        delete listings[listingId];

        emit ListingSold(listingId, msg.sender);
    }

    function removeListing(uint256 listingId) public nonReentrant {
        require(tx.origin == _msgSender(), "Contracts are prohibited");
        require(isListingActive(listingId), "Listing is not active");
        Listing memory listing = listings[listingId];
        require(listing.owner == _msgSender(), "Not authorized");
        titanLegends.safeTransferFrom(
            address(this),
            msg.sender,
            listing.tokenId
        );

        activeListings.remove(listingId);
        delete listings[listingId];
        emit ListingRemoved(listingId);
    }

    function editListing(uint256 listingId, uint256 newPrice) public {
        require(tx.origin == _msgSender(), "Contracts are prohibited");
        require(isListingActive(listingId), "Listing is not active");
        Listing storage listing = listings[listingId];
        require(listing.owner == _msgSender(), "Not authorized");
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
        require(fee <= 800, "MArketplace fee should not exceed 8 percent");
        marketplaceFee = fee;
    }

    function setFeeStorage(address storageAdr) external onlyOwner {
        feeStorage = storageAdr;
    }
}

