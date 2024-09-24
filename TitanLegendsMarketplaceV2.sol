// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/interfaces/IERC721.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "./helpers/FullMath.sol";
import "./helpers/TickMath.sol";

contract TitanLegendsMarketplaceV2 is ERC721Holder, ReentrancyGuard, Ownable2Step {
    struct Listing {
        uint256 tokenId;
        uint256 price;
        address owner;
    }

    using EnumerableSet for EnumerableSet.UintSet;

    address private constant TITANX_WETH_POOL = 0xc45A81BC23A64eA556ab4CdF08A86B61cdcEEA8b;
    address private constant WETH9 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    uint256 public currentListingId;
    uint64 public marketplaceFee;
    address private feeStorage;
    IERC721 public immutable collection;
    IERC20 public immutable titanX;

    uint256 slippage = 5;

    mapping(uint256 => Listing) public listings;
    EnumerableSet.UintSet private activeListings;

    event ListingAdded(uint256 indexed listingId, uint256 indexed tokenId, address indexed owner, uint256 price);
    event ListingRemoved(uint256 indexed listingId);
    event ListingEdited(uint256 indexed listingId, uint256 price);
    event ListingSold(uint256 indexed listingId, uint256 tokenId, uint256 price, address buyer);

    modifier noContract() {
        require(address(msg.sender).code.length == 0, "Contracts are prohibited");
        _;
    }

    constructor(address nftAddress, address tokenAddress, address feeStorageAddress) Ownable(msg.sender) {
        collection = IERC721(nftAddress);
        titanX = IERC20(tokenAddress);
        marketplaceFee = 300;
        feeStorage = feeStorageAddress;
    }

    function addListing(uint256 tokenId, uint256 price) external nonReentrant noContract {
        require(price > 0, "Price must be greater than zero");
        uint256 listingId = currentListingId;
        collection.safeTransferFrom(msg.sender, address(this), tokenId);

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
        collection.safeTransferFrom(address(this), msg.sender, listing.tokenId);
        emit ListingSold(listingId, listing.tokenId, listing.price, msg.sender);
    }

    function buyListingEth(uint256 listingId, uint256 price) external payable nonReentrant noContract {
        require(isListingActive(listingId), "Listing is not active");
        Listing memory listing = listings[listingId];
        require(listing.price == price, "Incorrect price provided");
        uint256 ethPrice = getCurrentEthPrice();
        uint256 priceInEth = FullMath.mulDiv(price, ethPrice, 1e18);
        uint256 twap = getTWAP(10);
        if (twap > ethPrice) {
            require(twap - ethPrice <= ethPrice * slippage / 100, "Price changed");
        }
        require(msg.value >= priceInEth, "Insufficient ETH sent");
        uint256 _marketplaceFee = (priceInEth * marketplaceFee) / 10000;
        activeListings.remove(listingId);
        delete listings[listingId];

        (bool feeTx,) = feeStorage.call{value: _marketplaceFee}("");
        (bool ownerTx,) = listing.owner.call{value: priceInEth - _marketplaceFee}("");
        if (priceInEth < msg.value) {
            (bool refundTx,) = msg.sender.call{value: msg.value - priceInEth}("");
            require(refundTx, "RF1");
        }
        require(feeTx && ownerTx, "F1");
        collection.safeTransferFrom(address(this), msg.sender, listing.tokenId);
        emit ListingSold(listingId, listing.tokenId, listing.price, msg.sender);
    }

    function removeListing(uint256 listingId) external nonReentrant {
        require(isListingActive(listingId), "Listing is not active");
        Listing memory listing = listings[listingId];
        require(listing.owner == msg.sender, "Not authorized");
        activeListings.remove(listingId);
        delete listings[listingId];

        collection.safeTransferFrom(address(this), msg.sender, listing.tokenId);
        emit ListingRemoved(listingId);
    }

    function editListing(uint256 listingId, uint256 newPrice) external nonReentrant {
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

    function setSlippage(uint256 limit) external onlyOwner {
        require(limit < 101, "Slippage cannot be greater than 100%");
        slippage = limit;
    }

    function getTWAP(uint32 secondsAgo) public view returns (uint256 price) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = secondsAgo;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives,) = IUniswapV3Pool(TITANX_WETH_POOL).observe(secondsAgos);

        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];

        int24 arithmeticMeanTick = int24(tickCumulativesDelta / int56(int32(secondsAgo)));
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int56(int32(secondsAgo)) != 0)) arithmeticMeanTick--;

        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(arithmeticMeanTick);
        uint256 sqrtPriceX192 = uint256(sqrtPriceX96) * sqrtPriceX96;
        price = FullMath.mulDiv(sqrtPriceX192, 1e18, 1 << 192);
        price = 1e36 / price;
    }

    function getCurrentEthPrice() public view returns (uint256 price) {
        IUniswapV3Pool pool = IUniswapV3Pool(TITANX_WETH_POOL);
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();

        uint256 sqrtPriceX192 = uint256(sqrtPriceX96) * sqrtPriceX96;
        price = FullMath.mulDiv(sqrtPriceX192, 1e18, 1 << 192);
        price = 1e36 / price;
    }
}
