// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../DutchAuction.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol"; // Import the provided DutchAuction abstract contract

/**
 * @title NftDutchAuction
 * @notice Example of a simple NFT collection using the DutchAuction contract.
 *         For simplicity, all NFTs are pre-minted to the auction contract.
 *
 *
 * Note: This contract is just an example. When launching a new collection,
 *       you would usually mint the NFTs directly to the buyer instead of holding them in the auction contract.
 */
contract NftDutchAuction is ERC721, DutchAuction {
    /// @notice The base URI for the NFT metadata
    string private baseTokenURI;

    /// @notice The tokenID of the next NFT to sell
    uint256 private nextTokenIdToSell;

    /**
     * @param _seller The address of the seller
     * @param _startPrice The initial price per NFT at the auction start
     * @param _floorPrice The minimum price per NFT at the auction end
     * @param _startTime The timestamp when the auction starts
     * @param _duration The duration of the auction in seconds
     * @param _inventory How many NFTs will be sold
     * @param _baseTokenURI The base URI for token metadata
     */
    constructor(
        address _seller,
        uint256 _startPrice,
        uint256 _floorPrice,
        uint256 _startTime,
        uint256 _duration,
        uint256 _inventory,
        string memory _baseTokenURI
    )
        ERC721("ExampleCollection", "EXC")
        DutchAuction(_seller, _startPrice, _floorPrice, _startTime, _duration, _inventory)
    {
        baseTokenURI = _baseTokenURI;

        // Pre-mint all NFTs to this contract so they can be sold.
        // For simplicity, token IDs start at 1 and go up to _inventory.
        // The auction will sell them in order from 1 to _inventory.
        for (uint256 i = 1; i <= _inventory; i++) {
            _mint(address(this), i);
        }

        // Set the next token ID to sell
        nextTokenIdToSell = 1;
    }

    /**
     * @notice Override the default ERC721 baseURI
     */
    function _baseURI() internal view override returns (string memory) {
        return baseTokenURI;
    }

    /**
     * @dev Implements the required hook from DutchAuction to transfer purchased items.
     * @param buyer The address of the buyer
     * @param quantity The number of NFTs to transfer
     *
     * Since all items are identical (just different token IDs), we give the buyer
     * the next `quantity` tokenIDs sequentially.
     */
    function _transferAssetToBuyer(address buyer, uint256 quantity) internal override {
        // Transfer `quantity` NFTs sequentially from the contract to the buyer.
        for (uint256 i = 0; i < quantity; i++) {
            uint256 tokenIdToTransfer = nextTokenIdToSell;
            nextTokenIdToSell++;
            _safeTransfer(address(this), buyer, tokenIdToTransfer, "");
        }
    }

    /**
     * @dev Implements the required hook from DutchAuction to transfer unsold items back to the seller.
     * @param seller The seller's address
     * @param quantity The quantity of unsold NFTs
     *
     * Since some NFTs remain unsold at auction end, we transfer them all to `seller_`.
     */
    function _withdrawUnsoldAssets(address seller, uint256 quantity) internal override {
        // Transfer each remaining NFT to the seller.
        // At this point, nextTokenIdToSell indicates how many were sold.
        // Unsold NFTs are from nextTokenIdToSell to nextTokenIdToSell + quantity - 1.
        for (uint256 i = 0; i < quantity; i++) {
            uint256 tokenIdToTransfer = nextTokenIdToSell + i;
            _safeTransfer(address(this), seller, tokenIdToTransfer, "");
        }
        // Update nextTokenIdToSell is optional since auction ended. But for completeness:
        nextTokenIdToSell += quantity;
    }
}
