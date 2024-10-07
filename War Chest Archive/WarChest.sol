// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "erc721a/contracts/ERC721A.sol";
import "./interfaces/IERC20Burnable.sol";

contract WarChest is ERC2981, ERC721A, Ownable2Step {
    using SafeERC20 for IERC20Burnable;
    using Strings for uint256;

    // --------------------------- STATE VARIABLES --------------------------- //

    IERC20Burnable constant LegendX = IERC20Burnable(0xDB04fb08378129621634C151E9b61FEf56947920);
    uint256 public constant price = 88_888 ether;
    uint256 public constant burnFee = 2_666.64 ether;

    uint64 public maxSupply = 8888;
    bool public isSaleActive;

    string private baseURI;
    string public contractURI;

    // --------------------------- ERRORS & EVENTS --------------------------- //

    error SaleInactive();
    error SupplyExceeded();
    error ZeroInput();
    error Prohibited();
    error Unauthorized();

    event SaleUpdated(bool active);
    event Mint(uint256 amount);
    event Remint(uint256 amount);
    event Claim(uint256 amount);
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);
    event ContractURIUpdated();
    
    // --------------------------- CONSTRUCTOR --------------------------- //

    constructor(string memory contractURI_, string memory baseURI_) ERC721A("Warlords", "WRLRD") Ownable(msg.sender) {
        if (bytes(contractURI_).length == 0) revert ZeroInput();
        if (bytes(baseURI_).length == 0) revert ZeroInput();
        contractURI = contractURI_;
        baseURI = baseURI_;
        _setDefaultRoyalty(0xF279986D7ac76bEE90C55928536867981C400319, 800);
    }

    // --------------------------- PUBLIC FUNCTIONS --------------------------- //

    ///@notice Mints a specified amount of NFTs to the sender.
    ///@param amount The number of tokens to mint.
    function mint(uint256 amount) external {
        if (!isSaleActive) revert SaleInactive();
        if (amount == 0) revert ZeroInput();
        if (_totalMinted() + amount > maxSupply) revert SupplyExceeded();
        uint256 burnSum = amount * burnFee;
        uint256 totalSum = amount * price + burnSum;
        LegendX.safeTransferFrom(msg.sender, address(this), totalSum);
        LegendX.burn(burnSum);
        _mint(msg.sender, amount);
        emit Mint(amount);
    }

    ///@notice Burns a list of existing tokens and remints new to the sender.
    ///@param tokenIds The list of token IDs to burn and remint.
    function remint(uint256[] calldata tokenIds) external {
        uint256 amount = tokenIds.length;
        if (!isSaleActive) revert SaleInactive();
        if (amount == 0) revert ZeroInput();
        if (_totalMinted() + amount > maxSupply) revert SupplyExceeded();
        address originalOwner = ownerOf(tokenIds[0]);
        if (originalOwner != msg.sender) revert Unauthorized();
        for (uint i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            if (ownerOf(tokenId) != originalOwner) revert Unauthorized();
            _burn(tokenId);
        }
        uint256 burnSum = burnFee * amount;
        LegendX.safeTransferFrom(msg.sender, address(this), burnSum);
        LegendX.burn(burnSum);
        _mint(msg.sender, amount);
        emit Remint(amount);
    }

    ///@notice Burns NFTs and claim locked LGNDX amount (less the burn fee).
    ///@param tokenIds The list of token IDs to claim and burn.
    function claim(uint256[] calldata tokenIds) external {
        uint256 amount = tokenIds.length;
        if (amount == 0) revert ZeroInput();
        address originalOwner = ownerOf(tokenIds[0]);
        if (originalOwner != msg.sender) revert Unauthorized();
        for (uint i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            if (ownerOf(tokenId) != originalOwner) revert Unauthorized();
            _burn(tokenId);
        }
        uint256 claimSum = price * amount;
        uint256 burnSum = burnFee * amount;
        LegendX.burn(burnSum);
        LegendX.safeTransfer(msg.sender, claimSum - burnSum);
        emit Claim(amount);
    }

    // --------------------------- ADMINISTRATIVE FUNCTIONS --------------------------- //

    ///@notice Sets the base URI for the token metadata.
    ///@param uri The new base URI to set.
    function setBaseURI(string memory uri) external onlyOwner {
        if (bytes(uri).length == 0) revert ZeroInput();
        baseURI = uri;
        emit BatchMetadataUpdate(1, type(uint256).max);
    }

    ///@notice Sets the contract-level metadata URI.
    ///@param uri The new contract URI to set.
    function setContractURI(string memory uri) external onlyOwner {
        if (bytes(uri).length == 0) revert ZeroInput();
        contractURI = uri;
        emit ContractURIUpdated();
    }

    ///@notice Toggles the sale state (active/inactive).
    function flipSaleState() external onlyOwner {
        isSaleActive = !isSaleActive;
        emit SaleUpdated(isSaleActive);
    }

    ///@notice Reduces the maximum supply of NFTs.
    ///@param newMaxSupply The new maximum supply to set.
    function cutSupply(uint64 newMaxSupply) external onlyOwner {
        if (newMaxSupply >= maxSupply) revert Prohibited();
        if (newMaxSupply < _totalMinted()) revert Prohibited();
        maxSupply = newMaxSupply;
    }

    // --------------------------- VIEW FUNCTIONS --------------------------- //
    
    /// @notice Returns total number of minted NFTs.
    function totalMinted() external view returns(uint256) {
        return _totalMinted();
    }

    /// @notice Returns total number of burned NFTs.
    function totalBurned() external view returns(uint256) {
        return _totalBurned();
    }

    /// @notice Returns all existing token IDs.
    /// @return tokenIds An array of existing token IDs.
    /// @dev Should not be called by contracts.
    function existingTokenIds() external view returns (uint256[] memory tokenIds) {
        uint256 totalTokenIds = _nextTokenId();
        uint256 supply = totalSupply();
        tokenIds = new uint256[](supply);
        uint256 counter;
        for (uint256 tokenId = 1; tokenId < totalTokenIds; tokenId++) {
            if (_exists(tokenId)) {
                tokenIds[counter++] = tokenId;
                if (counter == supply) return tokenIds;
            }
        }
    }

    /// @notice Returns all token IDs owned by a specific account.
    /// @param account The address of the token owner.
    /// @return tokenIds An array of token IDs owned by the account.
    /// @dev Should not be called by contracts.
    function tokenIdsOf(address account) external view returns (uint256[] memory tokenIds) {
        uint256 totalTokenIds = _nextTokenId();
        uint256 userBalance = balanceOf(account);
        tokenIds = new uint256[](userBalance);
        if (userBalance == 0) return tokenIds;
        uint256 counter;
        for (uint256 tokenId = 1; tokenId < totalTokenIds; tokenId++) {
            if (_exists(tokenId) && ownerOf(tokenId) == account) {
                tokenIds[counter] = tokenId;
                counter++;
                if (counter == userBalance) return tokenIds;
            }
        }
    }

    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        if (!_exists(tokenId)) revert URIQueryForNonexistentToken();
        return bytes(baseURI).length != 0 ? string(abi.encodePacked(baseURI, tokenId.toString(), ".json")) : "";
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721A, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function _startTokenId() internal view virtual override returns (uint256) {
        return 1;
    }
}
