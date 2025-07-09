# Makefile for deploying MockToken contract using Foundry

.PHONY: deploy-mock-token

deploy-mock-token:
	@forge script script/mock/DeployMockToken.s.sol \
		--rpc-url $$(grep -v '^#' .env | grep RPC_URL | cut -d '=' -f2) \
		--private-key $$(grep -v '^#' .env | grep PRIVATE_KEY | cut -d '=' -f2) \
		--broadcast \
		--verify \
		-vvvv
