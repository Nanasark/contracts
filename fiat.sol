// SPDX-License-Identifier: MIT
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

pragma solidity ^0.8.20;


contract BuyCryptoPlatform is ReentrancyGuard {
    address public owner;
    IERC20 private token;

    uint256 public totalFeesCollected; // Total fees collected by the platform for the current period
    uint256 public periodStartTime; // Timestamp of when the current period started
    uint256 public constant PERIOD_DURATION = 30 days; // Duration of the reward period (e.g., 30 days)
    
    uint256 public constant MERCHANT_SHARE = 40; // 40% to merchants
    uint256 public constant OWNER_SHARE = 60; // 60% to owner

    struct Merchant {
        bool isRegistered;
        uint256 stakedBalance; // Staked balance for transactions
        uint256 rewardBalance;
        address merchant;
    }

    mapping(address => Merchant) public merchants;
    mapping(address => bool) public isRegistered;
    address[] public merchantList; // List to keep track of all registered merchants

    // Define an array to hold allowed backend wallet addresses
    address[] public backendWallets;

    modifier onlyOwner() {
        require(msg.sender == owner, "Caller is not authorized");
        _;
    }

    modifier onlyRegisteredMerchant() {
        require(merchants[msg.sender].isRegistered, "Caller is not a registered merchant");
        _;
    }

    modifier onlyBackendWallet() {
        bool allowed = false;
        for (uint i = 0; i < backendWallets.length; i++) {
            if (msg.sender == backendWallets[i]) {
                allowed = true;
                break;
            }
        }
        require(allowed, "Caller is not an allowed backend wallet");
        _;
    }

    constructor(IERC20 _token) {
        token = _token;
        owner = msg.sender;
        periodStartTime = block.timestamp;
    }
    struct Transactions {
        address user;
        address merchant;
        uint256 amount;
        uint256 fee;
        bool isReceivedCrypto;  // If true, it means the user received crypto, otherwise the user bought crypto with fiat
        uint256 timestamp;      // Timestamp of the transaction
    }

    struct FiatToCryptoTransaction {
        address user;
        address merchant;
        uint256 amount;
        uint256 fee;
        uint256 timestamp;
    }

    struct CryptoToFiatTransaction {
        address user;
        address merchant;
        uint256 amount;
        uint256 fee;
        uint256 timestamp;
    }

    mapping(address => mapping(address => mapping(uint256 => FiatToCryptoTransaction[]))) public fiatToCryptoTransactions;
    mapping(address => mapping(address => mapping(uint256 => CryptoToFiatTransaction[]))) public cryptoToFiatTransactions;
    mapping(address => Transactions[]) public userTransactions;

    // Function to register merchants
    function registerMerchant(address _merchant) external {
        require(!merchants[msg.sender].isRegistered, "Already registered");
        merchants[msg.sender] = Merchant(true, 0, 0, _merchant );
        merchantList.push(msg.sender);
        isRegistered[_merchant] = true;
    }

    function removeMerchant(address _merchant) public onlyOwner {
        require(merchants[_merchant].isRegistered, "Not registered");
        
        // Find and remove the merchant from the list
        for (uint256 i = 0; i < merchantList.length; i++) {
            if (merchantList[i] == _merchant) {
                merchantList[i] = merchantList[merchantList.length - 1]; // Replace with the last element
                merchantList.pop(); // Remove the last element
                break;
            }
        }

        // Update mappings
        merchants[_merchant].isRegistered = false;
        isRegistered[_merchant] = false;
    }

    function getAllMerchants() external view returns (Merchant[] memory) {
    Merchant[] memory allMerchants = new Merchant[](merchantList.length);
    for (uint i = 0; i < merchantList.length; i++) {
        address merchantAddress = merchantList[i];
        allMerchants[i] = merchants[merchantAddress];
    }
    return allMerchants;
}

// Function to get merchant details by their address
function getMerchantByAddress(address merchantAddress) external view returns (Merchant memory) {
    require(merchants[merchantAddress].isRegistered, "Merchant not registered");
    return merchants[merchantAddress];
}


    // Function for merchants to stake tokens
    function stakeTokens(uint256 amount) external onlyRegisteredMerchant {
        require(amount > 0, "Amount must be greater than zero");
        token.transferFrom(msg.sender, address(this), amount);
        merchants[msg.sender].stakedBalance += amount;
    }

    // Function for merchants to unstake tokens
    function unstakeTokens(uint256 amount) external onlyRegisteredMerchant {
        require(amount > 0, "Amount must be greater than zero");
        require(merchants[msg.sender].stakedBalance >= amount, "Insufficient staked balance");
        merchants[msg.sender].stakedBalance -= amount;
        token.transfer(msg.sender, amount);
    }

// View real-time rewards for a merchant
function getRealTimeReward(address merchant) external view returns (uint256) {
    require(merchants[merchant].isRegistered, "Merchant not registered");
    
    // Calculate the total staked balance of all merchants
    uint256 totalStakedBalance = getTotalStakedBalance();
    require(totalStakedBalance > 0, "No staked balance available");
    
    // Calculate the merchant fee pool for the current period
    uint256 merchantFeePool = (totalFeesCollected * MERCHANT_SHARE) / 100;

    // Calculate the merchant's share of the fee pool
    uint256 merchantRewardShare = (merchants[merchant].stakedBalance * merchantFeePool) / totalStakedBalance;
    
    // Return the reward (includes unclaimed rewards from previous periods)
    return merchants[merchant].rewardBalance + merchantRewardShare;
}

    // Calculate the fee based on transaction amount
    function calculateFee(uint256 amount) public pure returns (uint256) {
        if (amount <= 100 ether) {
            return (amount * 50) / 10000; // 5%
        } else if (amount <= 1000 ether) {
            return (amount * 30) / 10000; // 3%
        } else {
            return (amount * 10) / 10000; // 1%
        }
    }

    // Events
    event CryptoPurchasedWithFiat(
        address indexed user,
        uint256 amount,
        address indexed merchant,
        uint256 fee,
        uint256 merchantReward,
        uint256 ownerReward
    );

    event CryptoSoldForFiat(
        address indexed user,
        uint256 amount,
        address indexed merchant,
        uint256 fee,
        uint256 merchantReward,
        uint256 ownerReward
    );

    // Buy crypto with fiat
    function buyCryptoWithFiat(address user, uint256 amount, address merchant) external nonReentrant onlyBackendWallet {
        require(merchants[merchant].isRegistered, "Invalid merchant");
        uint256 fee = calculateFee(amount);
        totalFeesCollected += fee;

        // Deduct crypto from merchant's staked balance
        require(merchants[merchant].stakedBalance >= amount, "Merchant has insufficient staked balance");
        merchants[merchant].stakedBalance -= amount;

        // Send crypto to the user
        require(token.balanceOf(address(this)) >= amount, "Insufficient contract balance");
        token.transfer(user, amount);

        // Calculate share of the total fee for merchant and owner
        uint256 merchantFeeShare = (fee * MERCHANT_SHARE) / 100;
        uint256 ownerFeeShare = (fee * OWNER_SHARE) / 100;

        // Platform retains the owner's share
        token.transfer(owner, ownerFeeShare);

           FiatToCryptoTransaction memory newTransaction = FiatToCryptoTransaction({
            user: user,
            merchant: merchant,
            amount: amount,
            fee: fee,
            timestamp: block.timestamp
        });


        // Store the transaction in the mapping for this user and merchant
        fiatToCryptoTransactions[user][merchant][amount].push(newTransaction);
         addTransaction(user, merchant, amount, fee, true);

        // Emit the event for the transaction
        emit CryptoPurchasedWithFiat(
            user,
            amount,
            merchant,
            fee,
            merchantFeeShare,
            ownerFeeShare
        );
    }

    // Buy fiat with crypto
    function buyFiatWithCrypto(address user, uint256 amount, address merchant) external nonReentrant  {
        require(merchants[merchant].isRegistered, "Invalid merchant");
        uint256 fee = calculateFee(amount);
        totalFeesCollected += fee;

       
        // User sends crypto to the contract
        uint256 estimatedAmount =amount-fee;

         // Add crypto to the merchant's staked balance
        token.transferFrom(msg.sender, address(this), estimatedAmount);

        merchants[merchant].stakedBalance += estimatedAmount;

        // Calculate share of the total fee for merchant and owner
        uint256 merchantFeeShare = (fee * MERCHANT_SHARE) / 100;
        uint256 ownerFeeShare = (fee * OWNER_SHARE) / 100;

        // Platform retains the owner's share
        token.transfer(owner, ownerFeeShare);

        CryptoToFiatTransaction memory newTransaction = CryptoToFiatTransaction({
            user: user,
            merchant: merchant,
            amount: amount,
            fee: fee,
            timestamp: block.timestamp
        });



        // Store the transaction in the mapping for this user and merchant
        cryptoToFiatTransactions[user][merchant][amount].push(newTransaction);

         addTransaction(user, merchant, amount, fee, false);

            // Emit the event for the transaction
            emit CryptoSoldForFiat(
                user,
                amount,
                merchant,
                fee,
                merchantFeeShare,
                ownerFeeShare
            );
    }

    function addTransaction(address user, address merchant, uint256 amount, uint256 fee, bool isReceivedCrypto) internal {
        Transactions memory newTransaction = Transactions({
            user: user,
            merchant: merchant,
            amount: amount,
            fee: fee,
            isReceivedCrypto: isReceivedCrypto,
            timestamp: block.timestamp
        });

        userTransactions[user].push(newTransaction);
    }

    function getAllTransactionsForUser(address user) external view returns (Transactions[] memory) {
        return userTransactions[user];
    }

    // End of period (e.g., monthly) reward calculation
    function endPeriodAndDistributeRewards() external onlyOwner {
        require(block.timestamp >= periodStartTime + PERIOD_DURATION, "Period has not ended yet");

        // Calculate total staked balance
        uint256 totalStakedBalance = getTotalStakedBalance();
        require(totalStakedBalance > 0, "No staked balance available");

        // Calculate merchant rewards
        uint256 merchantFeePool = (totalFeesCollected * MERCHANT_SHARE) / 100;
        for (uint i = 0; i < merchantList.length; i++) {
            address merchantAddress = merchantList[i];
            if (merchants[merchantAddress].isRegistered) {
                // Calculate merchant's reward share based on their staked balance
                uint256 merchantRewardShare = (merchants[merchantAddress].stakedBalance * merchantFeePool) / totalStakedBalance;
                merchants[merchantAddress].rewardBalance += merchantRewardShare;
            }
        }

        // Reset fee pool for the next period
        totalFeesCollected = 0;
        periodStartTime = block.timestamp; // Reset the start time for the new period
    }

    function getLatestCryptoToFiatTransaction(address user, address merchant,uint256 amount) external view returns (CryptoToFiatTransaction memory) {
    // Get all transactions for the user and merchant
    CryptoToFiatTransaction[] storage transactions = cryptoToFiatTransactions[user][merchant][amount];
    
    // Check if there are any transactions
    require(transactions.length > 0, "No transactions found for this user and merchant.");
    
    // Find the latest transaction by comparing timestamps
    CryptoToFiatTransaction memory latestTransaction = transactions[0]; // Initialize with the first transaction
    for (uint i = 1; i < transactions.length; i++) {
        if (transactions[i].timestamp > latestTransaction.timestamp) {
            latestTransaction = transactions[i]; // Update if a later transaction is found
        }
    }
    
    return latestTransaction;
}

function getLatestFiatToCryptoTransaction(address user, address merchant, uint256 amount) external view returns (FiatToCryptoTransaction memory) {
    // Get all transactions for the user and merchant
    FiatToCryptoTransaction[] storage transactions = fiatToCryptoTransactions[user][merchant][amount];
    
    // Check if there are any transactions
    require(transactions.length > 0, "No transactions found for this user and merchant.");
    
    // Find the latest transaction by comparing timestamps
    FiatToCryptoTransaction memory latestTransaction = transactions[0]; // Initialize with the first transaction
    for (uint i = 1; i < transactions.length; i++) {
        if (transactions[i].timestamp > latestTransaction.timestamp) {
            latestTransaction = transactions[i]; // Update if a later transaction is found
        }
    }
    
    return latestTransaction;
}



    // Claim rewards after the period ends
    function claimRewards() external onlyRegisteredMerchant {
        uint256 reward = merchants[msg.sender].rewardBalance;
        require(reward > 0, "No rewards to claim");
        merchants[msg.sender].rewardBalance = 0;
        token.transfer(msg.sender, reward);
    }

    // Withdraw accumulated fees by the platform owner
    function withdrawOwnerFees(uint256 amount) external onlyOwner {
        uint256 ownerShare = (totalFeesCollected * OWNER_SHARE) / 100;
        require(amount <= ownerShare, "Amount exceeds owner's share");
        totalFeesCollected -= amount;
        token.transfer(owner, amount);
    }

    // Function to add backend wallets (for fiat-to-crypto transactions)
    function addBackendWallet(address newWallet) external onlyOwner {
        backendWallets.push(newWallet);
    }

    // Function to remove backend wallets (for fiat-to-crypto transactions)
    function removeBackendWallet(address wallet) external onlyOwner {
        for (uint i = 0; i < backendWallets.length; i++) {
            if (backendWallets[i] == wallet) {
                backendWallets[i] = backendWallets[backendWallets.length - 1];
                backendWallets.pop();
                break;
            }
        }
    }

    // View merchant reward balance
    function getMerchantRewardBalance(address merchant) external view returns (uint256) {
        return merchants[merchant].rewardBalance;
    }

    // View merchant staked balance
    function getMerchantStakedBalance(address merchant) external view returns (uint256) {
        return merchants[merchant].stakedBalance;
    }

    // View total staked balance of all merchants
    function getTotalStakedBalance() public view returns (uint256) {
        uint256 total = 0;
        for (uint i = 0; i < merchantList.length; i++) {
            total += merchants[merchantList[i]].stakedBalance;
        }
        return total;
    }

    // Get contract token balance
    function getContractTokenBalance() public view returns (uint256) {
        return token.balanceOf(address(this));
    }

    // Transfer ownership
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "New owner is the zero address");
        owner = newOwner;
    }
}
