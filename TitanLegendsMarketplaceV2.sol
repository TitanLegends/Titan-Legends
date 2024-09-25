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
import "./helpers/OracleLibrary.sol";

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
    
    uint32 public secondsAgo = 5 * 60;
    uint32 public deviation = 300;

    address private feeStorage;
    IERC721 public immutable collection;
    IERC20 public immutable titanX;

    mapping(uint256 => Listing) public listings;
    EnumerableSet.UintSet private activeListings;

    error IncorrectAddress();
    error ZeroPrice();
    error InactiveListing();
    error IncorrectPrice();
    error IncorrectInput();
    error InsufficientEth();
    error Unauthorized();
    error ContractProhibited();
    error Deviation();

    event ListingAdded(uint256 indexed listingId, uint256 indexed tokenId, address indexed owner, uint256 price);
    event ListingRemoved(uint256 indexed listingId);
    event ListingEdited(uint256 indexed listingId, uint256 price);
    event ListingSold(uint256 indexed listingId, uint256 tokenId, uint256 price, address buyer);

    modifier noContract() {
        if (address(msg.sender).code.length > 0) revert ContractProhibited();
        _;
    }

    constructor(address nftAddress, address tokenAddress, address feeStorageAddress) Ownable(msg.sender) {
        if (nftAddress == address(0)) revert IncorrectAddress();
        if (tokenAddress == address(0)) revert IncorrectAddress();
        if (feeStorageAddress == address(0)) revert IncorrectAddress();
        collection = IERC721(nftAddress);
        titanX = IERC20(tokenAddress);
        marketplaceFee = 300;
        feeStorage = feeStorageAddress;
    }

    function addListing(uint256 tokenId, uint256 price) external nonReentrant noContract {
        if (price == 0) revert ZeroPrice();
        uint256 listingId = currentListingId++;
        collection.safeTransferFrom(msg.sender, address(this), tokenId);

        listings[listingId] = Listing(tokenId, price, msg.sender);
        activeListings.add(listingId);
        emit ListingAdded(listingId, tokenId, msg.sender, price);
    }

    function buyListing(uint256 listingId, uint256 price) external nonReentrant {
        if (!isListingActive(listingId)) revert InactiveListing();
        Listing memory listing = listings[listingId];
        if (listing.price != price) revert IncorrectPrice();
        uint256 _marketplaceFee = _calculateFee(listing.price);
        activeListings.remove(listingId);
        delete listings[listingId];

        titanX.transferFrom(msg.sender, feeStorage, _marketplaceFee);
        titanX.transferFrom(msg.sender, listing.owner, listing.price - _marketplaceFee);
        collection.safeTransferFrom(address(this), msg.sender, listing.tokenId);
        emit ListingSold(listingId, listing.tokenId, listing.price, msg.sender);
    }

    function buyListingEth(uint256 listingId, uint256 price) external payable nonReentrant noContract {
        if (!isListingActive(listingId)) revert InactiveListing();
        Listing memory listing = listings[listingId];
        if (listing.price != price) revert IncorrectPrice();

        uint256 twapPrice = getTwapPrice();
        uint256 spotPrice = getSpotPrice();
        uint256 diff = twapPrice >= spotPrice ? twapPrice - spotPrice : spotPrice - twapPrice;
        if(FullMath.mulDiv(spotPrice, deviation, 10000) < diff) revert Deviation();

        uint256 priceInEth = FullMath.mulDiv(price, spotPrice, 1e18);
        if (msg.value < priceInEth) revert InsufficientEth();

        uint256 _marketplaceFee = _calculateFee(priceInEth);
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
        if (!isListingActive(listingId)) revert InactiveListing();
        Listing memory listing = listings[listingId];
        if (listing.owner != msg.sender) revert Unauthorized();
        activeListings.remove(listingId);
        delete listings[listingId];

        collection.safeTransferFrom(address(this), msg.sender, listing.tokenId);
        emit ListingRemoved(listingId);
    }

    function editListing(uint256 listingId, uint256 newPrice) external nonReentrant {
        if (!isListingActive(listingId)) revert InactiveListing();
        Listing storage listing = listings[listingId];
        if (listing.owner != msg.sender) revert Unauthorized();
        if (newPrice == 0) revert ZeroPrice();

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
        if (fee > 800) revert IncorrectInput();
        if (fee == 0) revert IncorrectInput();
        marketplaceFee = fee;
    }

    function setFeeStorage(address storageAdr) external onlyOwner {
        if (storageAdr == address(0)) revert IncorrectAddress();
        feeStorage = storageAdr;
    }

    function setSecondsAgo(uint32 limit) external onlyOwner {
        if (limit == 0) revert IncorrectInput();
        secondsAgo = limit;
    }

    function setDeviation(uint32 limit) external onlyOwner {
        if (limit == 0) revert IncorrectInput();
        if (limit > 10000) revert IncorrectInput();
        deviation = limit;
    }

    function getTwapPrice() public view returns (uint256 quote) {
        address poolAddress = TITANX_WETH_POOL;
        uint32 _secondsAgo = secondsAgo;
        uint32 oldestObservation = OracleLibrary.getOldestObservationSecondsAgo(poolAddress);
        if (oldestObservation < _secondsAgo) _secondsAgo = oldestObservation;

        (int24 arithmeticMeanTick,) = OracleLibrary.consult(poolAddress, _secondsAgo);
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(arithmeticMeanTick);

        quote = OracleLibrary.getQuoteForSqrtRatioX96(sqrtPriceX96, 1e18, address(titanX), WETH9);
    }

    function getSpotPrice() public view returns (uint256) {
        IUniswapV3Pool pool = IUniswapV3Pool(TITANX_WETH_POOL);
        (uint256 sqrtPriceX96, , , , , , ) = pool.slot0();
        uint256 numerator1 = sqrtPriceX96 ** 2;
        uint256 price = FullMath.mulDiv(numerator1, 1e18, 1 << 192);
        price = 1e36 / price;
        return price;
    }

    function _calculateFee(uint256 value) internal view returns (uint256) {
        return FullMath.mulDivRoundingUp(value, marketplaceFee, 10000);
    }
}
