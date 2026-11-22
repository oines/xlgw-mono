FLUTTER ?= flutter

.PHONY: backend console mobile-web mobile-android mobile-mock-apk test test-console

backend:
	go -C backend run ./cmd/harbor

console:
	cd apps/console && npm ci && npm run build

mobile-web:
	cd apps/mobile && $(FLUTTER) pub get && $(FLUTTER) build web --base-href /mobile/

mobile-android:
	cd apps/mobile && $(FLUTTER) build apk --dart-define=HARBOR_API_URL=$(HARBOR_API_URL)

mobile-mock-apk:
	FLUTTER="$(FLUTTER)" ./scripts/export-mock-apk.sh

test:
	@test -n "$$XL_GW_TEST_DATABASE_URL" || (echo 'Set XL_GW_TEST_DATABASE_URL to a test PostgreSQL server with CREATEDB.'; exit 1)
	XL_GW_AI_TEST_DATABASE_URL="$$XL_GW_TEST_DATABASE_URL" go -C backend test -race -count=1 ./...
	cd apps/mobile && $(FLUTTER) analyze && $(FLUTTER) test

test-console:
	cd apps/console && npm run test:e2e
