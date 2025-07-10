# Makefile for SecureTransferLink and MockToken deployment

# Environment
ENV_FILE := .env
include $(ENV_FILE)
export $(shell sed 's/=.*//' $(ENV_FILE))

# Foundry commands
FORGE := forge
CAST := cast
ANVIL := anvil

# Network configuration (default: sepolia)
NETWORK ?= SEPOLIA
RPC_URL := $(shell grep '^$(NETWORK)_RPC_URL' $(ENV_FILE) | cut -d '=' -f2)

# Contracts
MOCK_TOKEN_SCRIPT := script/mock/DeployMockToken.s.sol
SECURE_TRANSFER_SCRIPT := script/DeploySecureTransfer.s.sol

.PHONY: all deploy-mock-token deploy-secure-transfer verify anvil fmt clean help

all: deploy-mock-token deploy-secure-transfer

# Deploy MockToken
deploy-mock-token:
	@echo "🚀 Deploying MockToken to $(NETWORK)..."
	@$(FORGE) script $(MOCK_TOKEN_SCRIPT) \
		--rpc-url $(RPC_URL) \
		--private-key $(PRIVATE_KEY) \
		--broadcast \
		--verify \
		-vvvv

# Deploy SecureTransferLink
deploy-secure-transfer:
	@echo "🚀 Deploying SecureTransferLink to $(NETWORK)..."
	@$(FORGE) script $(SECURE_TRANSFER_SCRIPT) \
		--rpc-url $(RPC_URL) \
		--private-key $$(grep -v '^#' .env | grep PRIVATE_KEY | cut -d '=' -f2) \
		--broadcast \
		--verify \
		-vvvv 

# Local development
anvil:
	@echo "🏗️  Starting Anvil local node..."
	@$(ANVIL)

# Format code
fmt:
	@echo "✨ Formatting code..."
	@$(FORGE) fmt

# Clean up
clean:
	@echo "🧹 Cleaning build artifacts..."
	@$(FORGE) clean

# Help
help:
	@echo "Available commands:"
	@echo "  deploy-mock-token      - Deploy MockToken contract"
	@echo "  deploy-secure-transfer - Deploy SecureTransferLink contract"
	@echo "  verify                 - Verify deployed contracts"
	@echo "  anvil                  - Start local Anvil node"
	@echo "  fmt                    - Format Solidity code"
	@echo "  clean                  - Clean build artifacts"
	@echo "  help                   - Show this help"
	@echo ""
	@echo "Environment variables:"
	@echo "  NETWORK                - Target network (default: sepolia)"
	@echo "  PRIVATE_KEY            - Your wallet private key"
	@echo "  FEE_COLLECTOR          - Address to receive fees"
	@echo "  FEE_BPS                - Fee in basis points (e.g., 100 for 1%)"
	@echo "  FIXED_FEE              - Fixed fee amount (in wei/micro-tokens)"
