// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title SecureTransferLink
 * @notice Gas-optimized secure token transfer system with direct payment and link/QR capabilities
 * @author Fahmi
 * @dev Implements CEI pattern, uses SafeERC20, and optimizes gas usage with packed structs
 */
contract SecureTransfer is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    // ========== CONSTANTS ==========
    uint16 public constant MAX_FEE_BASIS_POINTS = 1000; // 10%
    uint32 public constant MIN_EXPIRY_TIME = 1 hours;
    uint32 public constant MAX_EXPIRY_TIME = 30 days;
    uint32 public constant DEFAULT_EXPIRY_TIME = 24 hours;
    uint256 public constant MIN_TRANSFER_AMOUNT = 1000; // Prevent dust attacks

    // ========== ENUMS ==========
    enum TransferStatus {
        Pending, // 0: Transfer created but not claimed
        Claimed, // 1: Transfer claimed by recipient
        Refunded, // 2: Transfer refunded to sender
        Completed // 3: Direct transfer completed
    }

    // ========== STRUCTS ==========
    struct Transfer {
        address sender;
        address recipient; // Zero address for link transfers
        address tokenAddress;
        uint256 amount; // Net amount after fees
        uint256 grossAmount; // Original amount before fees
        uint32 expiry; // Packed to save gas
        bytes32 claimCodeHash; // keccak256 of claim code (if password protected)
        TransferStatus status;
        uint32 createdAt; // Packed to save gas
        bool isLinkTransfer;
        bool hasPassword;
        bool isDirectPayment; // For instant direct payments
    }

    // ========== STATE VARIABLES ==========
    mapping(bytes32 => Transfer) public transfers;
    mapping(address => bool) public supportedTokens;

    address public feeCollector;
    uint16 public feeInBasisPoints;
    uint256 public fixedFee;

    // Nonce for secure transfer ID generation
    uint256 private transferNonce;

    // ========== EVENTS ==========
    event TransferCreated(
        bytes32 indexed transferId,
        address indexed sender,
        address indexed recipient,
        address tokenAddress,
        uint256 netAmount,
        uint256 grossAmount,
        uint32 expiry,
        uint8 flags // bit 0: isLinkTransfer, bit 1: hasPassword, bit 2: isDirectPayment
    );

    event TransferClaimed(
        bytes32 indexed transferId,
        address indexed claimer,
        uint256 amount
    );

    event TransferRefunded(
        bytes32 indexed transferId,
        address indexed sender,
        uint256 amount
    );

    event DirectPaymentCompleted(
        bytes32 indexed transferId,
        address indexed sender,
        address indexed recipient,
        uint256 amount
    );

    event TokenSupportUpdated(address indexed tokenAddress, bool isSupported);

    event FeeUpdated(uint16 newFeeInBasisPoints, uint256 newFixedFee);
    event FeeCollectorUpdated(address indexed newFeeCollector);

    // ========== ERRORS ==========
    error InvalidTokenAddress();
    error InvalidRecipient();
    error InvalidAmount();
    error InvalidExpiryTime();
    error InvalidClaimCode();
    error InvalidFeeAmount();
    error ZeroFeeCollector();
    error TransferAlreadyExists();
    error TransferDoesNotExist();
    error TransferNotClaimable();
    error TransferNotRefundable();
    error TransferExpired();
    error TransferNotExpired();
    error NotIntendedRecipient();
    error NotTransferSender();
    error TokenNotSupported();
    error ArrayLengthMismatch();

    // ========== CONSTRUCTOR ==========
    constructor(
        address _feeCollector,
        uint16 _feeInBasisPoints,
        uint256 _fixedFee
    ) Ownable(msg.sender) {
        if (_feeCollector == address(0)) revert ZeroFeeCollector();
        if (_feeInBasisPoints > MAX_FEE_BASIS_POINTS) revert InvalidFeeAmount();

        feeCollector = _feeCollector;
        feeInBasisPoints = _feeInBasisPoints;
        fixedFee = _fixedFee;
    }

    // ========== DIRECT PAYMENT FUNCTIONS ==========

    /**
     * @notice Creates a direct instant payment to recipient (no claim needed)
     * @param recipient The recipient address
     * @param tokenAddress The ERC20 token address
     * @param amount The gross amount of tokens to transfer
     * @return transferId The unique ID of the payment
     */
    function createDirectPayment(
        address recipient,
        address tokenAddress,
        uint256 amount
    ) external nonReentrant whenNotPaused returns (bytes32) {
        // Checks
        if (recipient == address(0)) revert InvalidRecipient();
        if (tokenAddress == address(0)) revert InvalidTokenAddress();
        if (amount < MIN_TRANSFER_AMOUNT) revert InvalidAmount();
        if (!supportedTokens[tokenAddress]) revert TokenNotSupported();

        // Calculate fee and net amount
        uint256 percentageFee = (amount * feeInBasisPoints) / 10000;
        uint256 totalFee = fixedFee + percentageFee;
        uint256 netAmount = amount - totalFee;

        // Ensure net amount is not zero
        if (netAmount == 0) revert InvalidAmount();

        // Generate unique transfer ID
        bytes32 transferId = _generateTransferId(
            recipient,
            tokenAddress,
            amount
        );

        // Ensure transfer doesn't already exist
        if (transfers[transferId].createdAt != 0)
            revert TransferAlreadyExists();

        // Cache current timestamp
        uint32 currentTime = uint32(block.timestamp);

        // Effects - Create transfer record
        transfers[transferId] = Transfer({
            sender: msg.sender,
            recipient: recipient,
            tokenAddress: tokenAddress,
            amount: netAmount,
            grossAmount: amount,
            expiry: 0, // No expiry for direct payments
            claimCodeHash: bytes32(0),
            status: TransferStatus.Completed,
            createdAt: currentTime,
            isLinkTransfer: false,
            hasPassword: false,
            isDirectPayment: true
        });

        // Interactions - Transfer tokens from sender
        IERC20(tokenAddress).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );

        // Transfer fee to fee collector if applicable
        if (totalFee > 0) {
            IERC20(tokenAddress).safeTransfer(feeCollector, totalFee);
        }

        // Transfer net amount directly to recipient
        IERC20(tokenAddress).safeTransfer(recipient, netAmount);

        emit TransferCreated(
            transferId,
            msg.sender,
            recipient,
            tokenAddress,
            netAmount,
            amount,
            0,
            4 // bit 2 set for isDirectPayment
        );

        emit DirectPaymentCompleted(
            transferId,
            msg.sender,
            recipient,
            netAmount
        );

        return transferId;
    }

    // ========== TRANSFER CREATION ==========

    /**
     * @notice Creates a direct transfer to a specific recipient (requires claim)
     * @param recipient The recipient address
     * @param tokenAddress The ERC20 token address
     * @param amount The gross amount of tokens to transfer
     * @param expiry The timestamp after which transfer can be refunded (0 for default)
     * @param hasPassword Whether this transfer requires a password
     * @param claimCodeHash The hash of the claim code (required if hasPassword is true)
     * @return transferId The unique ID of the created transfer
     */
    function createDirectTransfer(
        address recipient,
        address tokenAddress,
        uint256 amount,
        uint32 expiry,
        bool hasPassword,
        bytes32 claimCodeHash
    ) external nonReentrant whenNotPaused returns (bytes32) {
        // Checks
        if (recipient == address(0)) revert InvalidRecipient();
        _validateTransferParams(
            tokenAddress,
            amount,
            expiry,
            hasPassword,
            claimCodeHash
        );

        // Create and process transfer
        return
            _createTransfer(
                recipient,
                tokenAddress,
                amount,
                expiry,
                hasPassword,
                claimCodeHash,
                false, // isLinkTransfer
                false // isDirectPayment
            );
    }

    /**
     * @notice Creates a link/QR transfer that can be claimed with just the transfer ID
     * @param tokenAddress The ERC20 token address
     * @param amount The gross amount of tokens to transfer
     * @param expiry The timestamp after which transfer can be refunded (0 for default)
     * @param hasPassword Whether this transfer requires a password
     * @param claimCodeHash The hash of the claim code (required if hasPassword is true)
     * @return transferId The unique ID of the created transfer
     */
    function createLinkTransfer(
        address tokenAddress,
        uint256 amount,
        uint32 expiry,
        bool hasPassword,
        bytes32 claimCodeHash
    ) external nonReentrant whenNotPaused returns (bytes32) {
        // Checks
        _validateTransferParams(
            tokenAddress,
            amount,
            expiry,
            hasPassword,
            claimCodeHash
        );

        // Create and process transfer
        return
            _createTransfer(
                address(0), // No specific recipient
                tokenAddress,
                amount,
                expiry,
                hasPassword,
                claimCodeHash,
                true, // isLinkTransfer
                false // isDirectPayment
            );
    }

    // ========== TRANSFER CLAIMING ==========

    /**
     * @notice Claims a transfer (works for both direct and link transfers)
     * @param transferId The ID of the transfer to claim
     * @param claimCode The plain text claim code (only needed for password-protected transfers)
     */
    function claimTransfer(
        bytes32 transferId,
        string calldata claimCode
    ) external nonReentrant whenNotPaused {
        Transfer storage transfer = transfers[transferId];

        // Checks
        if (transfer.createdAt == 0) revert TransferDoesNotExist();
        if (transfer.status != TransferStatus.Pending)
            revert TransferNotClaimable();
        if (uint32(block.timestamp) > transfer.expiry) revert TransferExpired();

        // Validate recipient (if specified)
        if (
            transfer.recipient != address(0) && msg.sender != transfer.recipient
        ) {
            revert NotIntendedRecipient();
        }

        // Validate password (if required)
        if (transfer.hasPassword) {
            if (
                keccak256(abi.encodePacked(claimCode)) != transfer.claimCodeHash
            ) {
                revert InvalidClaimCode();
            }
        }

        // Cache values before state change
        uint256 amount = transfer.amount;
        address tokenAddress = transfer.tokenAddress;

        // Effects - Update state BEFORE external call (CEI pattern)
        transfer.status = TransferStatus.Claimed;

        // Interactions - External call last
        IERC20(tokenAddress).safeTransfer(msg.sender, amount);

        emit TransferClaimed(transferId, msg.sender, amount);
    }

    // ========== TRANSFER REFUNDING ==========

    /**
     * @notice Refunds an expired transfer back to the sender
     * @param transferId The ID of the transfer to refund
     */
    function refundTransfer(
        bytes32 transferId
    ) external nonReentrant whenNotPaused {
        Transfer storage transfer = transfers[transferId];

        // Checks
        if (transfer.createdAt == 0) revert TransferDoesNotExist();
        if (transfer.status != TransferStatus.Pending)
            revert TransferNotRefundable();
        if (uint32(block.timestamp) <= transfer.expiry)
            revert TransferNotExpired();
        if (msg.sender != transfer.sender) revert NotTransferSender();

        // Cache values before state change
        uint256 amount = transfer.amount;
        address tokenAddress = transfer.tokenAddress;
        address sender = transfer.sender;

        // Effects - Update state BEFORE external call (CEI pattern)
        transfer.status = TransferStatus.Refunded;

        // Interactions - External call last
        IERC20(tokenAddress).safeTransfer(sender, amount);

        emit TransferRefunded(transferId, sender, amount);
    }

    /**
     * @notice Instantly refunds a transfer back to the sender (regardless of expiry)
     * @param transferId The ID of the transfer to refund
     */
    function instantRefund(
        bytes32 transferId
    ) external nonReentrant whenNotPaused {
        Transfer storage transfer = transfers[transferId];

        // Checks
        if (transfer.createdAt == 0) revert TransferDoesNotExist();
        if (transfer.status != TransferStatus.Pending)
            revert TransferNotRefundable();
        if (msg.sender != transfer.sender) revert NotTransferSender();

        // Cache values before state change
        uint256 amount = transfer.amount;
        address tokenAddress = transfer.tokenAddress;
        address sender = transfer.sender;

        // Effects - Update state BEFORE external call (CEI pattern)
        transfer.status = TransferStatus.Refunded;

        // Interactions - External call last
        IERC20(tokenAddress).safeTransfer(sender, amount);

        emit TransferRefunded(transferId, sender, amount);
    }

    // ========== VIEW FUNCTIONS ==========

    /**
     * @notice Gets the details of a transfer
     * @param transferId The ID of the transfer
     */
    function getTransfer(
        bytes32 transferId
    )
        external
        view
        returns (
            address sender,
            address recipient,
            address tokenAddress,
            uint256 amount,
            uint256 grossAmount,
            uint32 expiry,
            uint8 status,
            uint32 createdAt,
            bool isLinkTransfer,
            bool hasPassword,
            bool isDirectPayment
        )
    {
        Transfer storage transfer = transfers[transferId];
        if (transfer.createdAt == 0) revert TransferDoesNotExist();

        return (
            transfer.sender,
            transfer.recipient,
            transfer.tokenAddress,
            transfer.amount,
            transfer.grossAmount,
            transfer.expiry,
            uint8(transfer.status),
            transfer.createdAt,
            transfer.isLinkTransfer,
            transfer.hasPassword,
            transfer.isDirectPayment
        );
    }

    /**
     * @notice Checks if a transfer exists and is claimable
     * @param transferId The ID of the transfer
     * @return True if the transfer is claimable
     */
    function isTransferClaimable(
        bytes32 transferId
    ) external view returns (bool) {
        Transfer storage transfer = transfers[transferId];
        return (transfer.createdAt > 0 &&
            transfer.status == TransferStatus.Pending &&
            uint32(block.timestamp) <= transfer.expiry);
    }

    /**
     * @notice Checks if a transfer requires a password
     * @param transferId The ID of the transfer
     * @return 1 if password protected, 0 otherwise
     */
    function isPasswordProtected(
        bytes32 transferId
    ) external view returns (uint8) {
        Transfer storage transfer = transfers[transferId];
        if (transfer.createdAt == 0) revert TransferDoesNotExist();
        return transfer.hasPassword ? 1 : 0;
    }

    // ========== ADMIN FUNCTIONS ==========

    /**
     * @notice Sets token support status
     * @param tokenAddress The token address to update
     * @param isSupported Whether the token is supported
     */
    function setTokenSupport(
        address tokenAddress,
        bool isSupported
    ) external onlyOwner {
        if (tokenAddress == address(0)) revert InvalidTokenAddress();
        supportedTokens[tokenAddress] = isSupported;
        emit TokenSupportUpdated(tokenAddress, isSupported);
    }

    /**
     * @notice Batch sets token support for multiple tokens
     * @param tokenAddresses Array of token addresses
     * @param supportStatuses Array of support statuses
     */
    function batchSetTokenSupport(
        address[] calldata tokenAddresses,
        bool[] calldata supportStatuses
    ) external onlyOwner {
        uint256 length = tokenAddresses.length;
        if (length != supportStatuses.length) revert ArrayLengthMismatch();
        if (length == 0) revert InvalidAmount();

        for (uint256 i = 0; i < length; ) {
            address tokenAddress = tokenAddresses[i];
            if (tokenAddress == address(0)) revert InvalidTokenAddress();
            supportedTokens[tokenAddress] = supportStatuses[i];
            emit TokenSupportUpdated(tokenAddress, supportStatuses[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Sets the fee in basis points and fixed fee
     * @param newFeeInBasisPoints The new fee in basis points
     * @param newFixedFee The new fixed fee amount
     */
    function setFee(
        uint16 newFeeInBasisPoints,
        uint256 newFixedFee
    ) external onlyOwner {
        if (newFeeInBasisPoints > MAX_FEE_BASIS_POINTS)
            revert InvalidFeeAmount();
        feeInBasisPoints = newFeeInBasisPoints;
        fixedFee = newFixedFee;
        emit FeeUpdated(newFeeInBasisPoints, newFixedFee);
    }

    /**
     * @notice Sets the fee collector address
     * @param newFeeCollector The new fee collector address
     */
    function setFeeCollector(address newFeeCollector) external onlyOwner {
        if (newFeeCollector == address(0)) revert ZeroFeeCollector();
        feeCollector = newFeeCollector;
        emit FeeCollectorUpdated(newFeeCollector);
    }

    /**
     * @notice Pauses the contract
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses the contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ========== INTERNAL FUNCTIONS ==========

    /**
     * @notice Validates transfer parameters
     */
    function _validateTransferParams(
        address tokenAddress,
        uint256 amount,
        uint32 expiry,
        bool hasPassword,
        bytes32 claimCodeHash
    ) internal view {
        if (tokenAddress == address(0)) revert InvalidTokenAddress();
        if (amount < MIN_TRANSFER_AMOUNT) revert InvalidAmount();
        if (!supportedTokens[tokenAddress]) revert TokenNotSupported();
        if (hasPassword && claimCodeHash == bytes32(0))
            revert InvalidClaimCode();

        // Validate expiry
        if (expiry != 0) {
            uint32 currentTime = uint32(block.timestamp);
            if (
                expiry <= currentTime + MIN_EXPIRY_TIME ||
                expiry > currentTime + MAX_EXPIRY_TIME
            ) {
                revert InvalidExpiryTime();
            }
        }
    }

    /**
     * @notice Generates a unique transfer ID
     */
    function _generateTransferId(
        address recipient,
        address tokenAddress,
        uint256 amount
    ) internal returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    msg.sender,
                    recipient,
                    tokenAddress,
                    amount,
                    ++transferNonce,
                    block.timestamp
                )
            );
    }

    /**
     * @notice Creates a transfer with proper fee calculation and storage
     */
    function _createTransfer(
        address recipient,
        address tokenAddress,
        uint256 grossAmount,
        uint32 expiry,
        bool hasPassword,
        bytes32 claimCodeHash,
        bool isLinkTransfer,
        bool isDirectPayment
    ) internal returns (bytes32) {
        // Set default expiry if not provided
        if (expiry == 0) {
            expiry = uint32(block.timestamp) + DEFAULT_EXPIRY_TIME;
        }

        // Calculate fee and net amount
        uint256 percentageFee = (grossAmount * feeInBasisPoints) / 10000;
        uint256 totalFee = fixedFee + percentageFee;
        uint256 netAmount = grossAmount - totalFee;

        // Ensure net amount is not zero
        if (netAmount == 0) revert InvalidAmount();

        // Generate unique transfer ID
        bytes32 transferId = _generateTransferId(
            recipient,
            tokenAddress,
            grossAmount
        );

        // Ensure transfer doesn't already exist
        if (transfers[transferId].createdAt != 0)
            revert TransferAlreadyExists();

        // Cache current timestamp
        uint32 currentTime = uint32(block.timestamp);

        // Effects - Create transfer record
        transfers[transferId] = Transfer({
            sender: msg.sender,
            recipient: recipient,
            tokenAddress: tokenAddress,
            amount: netAmount,
            grossAmount: grossAmount,
            expiry: expiry,
            claimCodeHash: hasPassword ? claimCodeHash : bytes32(0),
            status: TransferStatus.Pending,
            createdAt: currentTime,
            isLinkTransfer: isLinkTransfer,
            hasPassword: hasPassword,
            isDirectPayment: isDirectPayment
        });

        // Interactions - Transfer tokens from sender
        IERC20(tokenAddress).safeTransferFrom(
            msg.sender,
            address(this),
            grossAmount
        );

        // Transfer fee to fee collector if applicable
        if (totalFee > 0) {
            IERC20(tokenAddress).safeTransfer(feeCollector, totalFee);
        }

        // Pack flags into single byte
        uint8 flags = (isLinkTransfer ? 1 : 0) |
            (hasPassword ? 2 : 0) |
            (isDirectPayment ? 4 : 0);

        emit TransferCreated(
            transferId,
            msg.sender,
            recipient,
            tokenAddress,
            netAmount,
            grossAmount,
            expiry,
            flags
        );

        return transferId;
    }
}
