# Phase 3: Connection & Authentication

**Objective**: Implement connection initialization, authentication, and connection testing.

**Time Estimate**: 45-60 minutes

**Prerequisite**: Phase 2 completed and verified.

---

## Prerequisites

### Essential Reading (MUST read before starting)

| File | What to Learn | Why It Matters |
|------|---------------|----------------|
| `supaflow-core/.../context/ConnectorRuntimeContext.java` | Runtime context interface | HTTP client, config access |
| `supaflow-core/.../model/datasource/DatasourceInitResponse.java` | Connection test response | How to return success/failure |
| `supaflow-core/.../http/HttpClientConfig.java` | HTTP client configuration | Timeout, proxy settings |
| `supaflow-core/.../exception/ConnectorException.java` | Auth exception | Use AUTHENTICATION_ERROR |
| Reference connector init() | Real examples | See patterns |

### Find Core Classes

```bash
# Find the classes to read
find . -name "ConnectorRuntimeContext.java" -path "*/supaflow-core/*"
find . -name "DatasourceInitResponse.java" -path "*/supaflow-core/*"
find . -name "HttpClientConfig.java" -path "*/supaflow-core/*"
find . -name "ConnectorException.java" -path "*/supaflow-core/*"
```

### Confirm Understanding

Before proceeding, you should be able to answer:

1. What does `ConnectorRuntimeContext` provide to the connector?
2. What fields does `DatasourceInitResponse` have?
3. When should you throw `ConnectorException` with `AUTHENTICATION_ERROR` vs other error types?
4. How do you get HTTP client configuration from ConnectorRuntimeContext?
5. What is the difference between OAuth2 Authorization Code and Client Credentials flows?

---

## Cancellation Setup (Required)

Every connector MUST wire cancellation early so downstream clients can use it.

```java
// In connector class
private volatile java.util.function.BooleanSupplier cancellationSupplier = () -> false;

@Override
public void setRuntimeContext(ConnectorRuntimeContext context) {
    this.runtimeContext = context;
    if (context != null) {
        this.cancellationSupplier = context.getCancellationSupplier();
    }
}
```

Pass the supplier into API/SDK clients or helpers and expose a lightweight check:

```java
private void checkCancellation(String phase) throws ConnectorException {
    if (cancellationSupplier != null && cancellationSupplier.getAsBoolean()) {
        throw new ConnectorException("Cancelled during " + phase,
                ConnectorException.ErrorType.CANCELLED);
    }
}
```

---

## Step 1: Understand Authentication Patterns

### Pattern 1: API Key / Token

Simplest pattern - user provides a static token:

```java
// Property
@Property(label = "API Token", type = PropertyType.STRING,
          encrypted = true, password = true, sensitive = true, required = true)
public String apiToken;

// Usage
Request request = new Request.Builder()
    .url(url)
    .header("Authorization", "Bearer " + apiToken)
    .build();
```

### Pattern 2: OAuth2 Client Credentials

Server-to-server authentication (like SFMC):

```java
// Exchange clientId + clientSecret for access_token
// No user interaction required
// Tokens typically expire quickly (20 minutes for SFMC)
```

### Pattern 3: OAuth2 Authorization Code

User-interactive authentication (like Airtable, HubSpot):

```java
// User clicks "Connect", browser opens
// User authorizes, callback provides code
// Code exchanged for access_token + refresh_token
// Frontend handles the flow, connector just uses tokens
```

---

## Step 2: Create HTTP Client Helper

Create a helper class for HTTP operations:

```java
package io.supaflow.connectors.{name}.client;

import okhttp3.MediaType;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.supaflow.core.exception.ConnectorException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.util.concurrent.TimeUnit;

public class {Name}RestClient {

    private static final Logger log = LoggerFactory.getLogger({Name}RestClient.class);
    private static final MediaType JSON = MediaType.parse("application/json; charset=utf-8");

    private final OkHttpClient httpClient;
    private final ObjectMapper objectMapper;
    private final String baseUrl;

    public {Name}RestClient(OkHttpClient httpClient, String baseUrl) {
        this.httpClient = httpClient;
        this.objectMapper = new ObjectMapper();
        this.baseUrl = baseUrl;
    }

    /**
     * Execute GET request with authentication.
     */
    public JsonNode get(String endpoint, String accessToken) throws IOException {
        String url = baseUrl + endpoint;
        log.debug("GET {}", url);

        Request request = new Request.Builder()
            .url(url)
            .header("Authorization", "Bearer " + accessToken)
            .header("Accept", "application/json")
            .build();

        return executeRequest(request);
    }

    /**
     * Execute POST request with JSON body.
     */
    public JsonNode post(String endpoint, Object body, String accessToken) throws IOException {
        String url = baseUrl + endpoint;
        String json = objectMapper.writeValueAsString(body);
        log.debug("POST {} with body length {}", url, json.length());

        Request request = new Request.Builder()
            .url(url)
            .header("Authorization", "Bearer " + accessToken)
            .header("Content-Type", "application/json")
            .header("Accept", "application/json")
            .post(RequestBody.create(json, JSON))
            .build();

        return executeRequest(request);
    }

    /**
     * Execute request and handle common error cases.
     */
    private JsonNode executeRequest(Request request) throws IOException {
        try (Response response = httpClient.newCall(request).execute()) {
            String responseBody = response.body() != null ? response.body().string() : "";

            if (!response.isSuccessful()) {
                handleErrorResponse(response.code(), responseBody);
            }

            if (responseBody.isEmpty()) {
                return objectMapper.createObjectNode();
            }

            return objectMapper.readTree(responseBody);
        }
    }

    /**
     * Handle HTTP error responses with appropriate exceptions.
     */
    private void handleErrorResponse(int code, String body) throws ConnectorException {
        log.error("HTTP {} response: {}", code, body);

        switch (code) {
            case 401:
                throw new ConnectorException(
                    "Authentication failed. Check your credentials. Response: " + body,
                    ConnectorException.ErrorType.AUTHENTICATION_ERROR);
            case 403:
                throw new ConnectorException(
                    "Access forbidden. Check permissions. Response: " + body,
                    ConnectorException.ErrorType.PERMISSION_ERROR);
            case 404:
                throw new ConnectorException(
                    "Resource not found: " + body,
                    ConnectorException.ErrorType.VALIDATION_ERROR);
            case 429:
                throw new ConnectorException(
                    "Rate limit exceeded. Retry later. Response: " + body,
                    ConnectorException.ErrorType.RATE_LIMIT_EXCEEDED);
            default:
                throw new ConnectorException(
                    "HTTP " + code + " error: " + body,
                    ConnectorException.ErrorType.SERVER_ERROR);
        }
    }
}
```

---

## Step 3: Implement Token Management (OAuth2 Client Credentials)

For connectors using Client Credentials flow:

```java
package io.supaflow.connectors.{name}.auth;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.supaflow.core.exception.ConnectorException;
import okhttp3.MediaType;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.time.Instant;
import java.util.HashMap;
import java.util.Map;

public class {Name}TokenManager {

    private static final Logger log = LoggerFactory.getLogger({Name}TokenManager.class);
    private static final MediaType JSON = MediaType.parse("application/json; charset=utf-8");
    private static final int TOKEN_REFRESH_BUFFER_SECONDS = 300;  // Refresh 5 min before expiry (handles long pagination loops)

    private final OkHttpClient httpClient;
    private final ObjectMapper objectMapper;
    private final String tokenUrl;
    private final String clientId;
    private final String clientSecret;
    private final String accountId;  // Some APIs require this

    // Cached token state
    private String accessToken;
    private Instant tokenExpiresAt;
    private String restBaseUrl;
    private String soapBaseUrl;

    public {Name}TokenManager(OkHttpClient httpClient, String subdomain,
                              String clientId, String clientSecret, String accountId) {
        this.httpClient = httpClient;
        this.objectMapper = new ObjectMapper();
        this.tokenUrl = String.format("https://%s.auth.marketingcloudapis.com/v2/token", subdomain);
        this.clientId = clientId;
        this.clientSecret = clientSecret;
        this.accountId = accountId;
    }

    /**
     * Get a valid access token, refreshing if necessary.
     */
    public synchronized String getAccessToken() throws IOException {
        if (isTokenValid()) {
            log.debug("Using cached access token, expires at {}", tokenExpiresAt);
            return accessToken;
        }

        log.info("Obtaining new access token from {}", tokenUrl);
        refreshToken();
        return accessToken;
    }

    /**
     * Check if cached token is still valid (with buffer).
     */
    private boolean isTokenValid() {
        if (accessToken == null || tokenExpiresAt == null) {
            return false;
        }
        return Instant.now().plusSeconds(TOKEN_REFRESH_BUFFER_SECONDS).isBefore(tokenExpiresAt);
    }

    /**
     * Request new access token using Client Credentials flow.
     */
    private void refreshToken() throws IOException, ConnectorException {
        Map<String, String> body = new HashMap<>();
        body.put("grant_type", "client_credentials");
        body.put("client_id", clientId);
        body.put("client_secret", clientSecret);
        if (accountId != null && !accountId.isEmpty()) {
            body.put("account_id", accountId);
        }

        Request request = new Request.Builder()
            .url(tokenUrl)
            .header("Content-Type", "application/json")
            .post(RequestBody.create(objectMapper.writeValueAsString(body), JSON))
            .build();

        try (Response response = httpClient.newCall(request).execute()) {
            String responseBody = response.body() != null ? response.body().string() : "";

            if (!response.isSuccessful()) {
                log.error("Token request failed with HTTP {}: {}", response.code(), responseBody);
                throw new ConnectorException(
                    "Failed to obtain access token: HTTP " + response.code() + " - " + responseBody,
                    ConnectorException.ErrorType.AUTHENTICATION_ERROR);
            }

            JsonNode tokenResponse = objectMapper.readTree(responseBody);

            // Extract token and expiry
            accessToken = tokenResponse.get("access_token").asText();
            int expiresIn = tokenResponse.has("expires_in")
                ? tokenResponse.get("expires_in").asInt()
                : 1200;  // Default 20 minutes
            tokenExpiresAt = Instant.now().plusSeconds(expiresIn);

            // Extract base URLs if provided (SFMC pattern)
            if (tokenResponse.has("rest_instance_url")) {
                restBaseUrl = tokenResponse.get("rest_instance_url").asText();
            }
            if (tokenResponse.has("soap_instance_url")) {
                soapBaseUrl = tokenResponse.get("soap_instance_url").asText();
            }

            log.info("Obtained new access token, expires at {}", tokenExpiresAt);
        }
    }

    /**
     * Force token refresh (e.g., after 401 error).
     */
    public synchronized void invalidateToken() {
        log.info("Invalidating cached access token");
        accessToken = null;
        tokenExpiresAt = null;
    }

    /**
     * Ensure token is valid before API calls.
     * Call this at the START of each pagination batch, not just once.
     */
    public void ensureValidToken() throws IOException {
        getAccessToken();  // Will refresh if within buffer window
    }

    // Getters for base URLs discovered during token exchange
    public String getRestBaseUrl() { return restBaseUrl; }
    public String getSoapBaseUrl() { return soapBaseUrl; }
}
```

---

## Step 4: Implement init() and setRuntimeContext()

The connector uses a two-phase initialization pattern:
1. `setRuntimeContext()` - Called first to provide system-wide configuration (optional)
2. `init()` - Called to initialize the connector with connection properties AND test the connection (required)

```java
// Instance variables
private ConnectorRuntimeContext runtimeContext;
private OkHttpClient httpClient;
private {Name}TokenManager tokenManager;
private {Name}RestClient restClient;

@Override
public void setRuntimeContext(ConnectorRuntimeContext context) {
    log.info("Setting runtime context for {} connector", getName());
    this.runtimeContext = context;
}

@Override
public DatasourceInitResponse init(Map<String, Object> connectionProperties) throws ConnectorException {
    log.info("Initializing {} connector", getName());

    try {
        // Step 1: Extract and validate connection properties
        extractConnectionProperties(connectionProperties);
        validateProperties();

        // Step 2: Create HTTP client from runtime context
        this.httpClient = createHttpClient();

        // Step 3: Initialize token manager
        this.tokenManager = new {Name}TokenManager(
            httpClient,
            subdomain,
            clientId,
            clientSecret,
            accountId
        );

        // Step 4: Initialize REST client
        String baseUrl = String.format("https://%s.rest.marketingcloudapis.com", subdomain);
        this.restClient = new {Name}RestClient(httpClient, baseUrl);

        // Step 5: Test connection by obtaining access token
        String token = tokenManager.getAccessToken();

        // Step 6: Make a simple API call to validate access
        JsonNode response = restClient.get("/platform/v1/endpoints", token);

        // Step 7: Return success response with metadata
        String productName = getName();
        String productVersion = "API v1";  // Or extract from response

        log.info("{} connector initialized and connection tested successfully", getName());

        return DatasourceInitResponse.builder()
            .success(true)
            .productName(productName)
            .productVersion(productVersion)
            .message("Connection successful")
            .build();

    } catch (ConnectorException e) {
        log.error("Connection test failed for {}: {}", getName(), e.getMessage());
        throw e;
    } catch (Exception e) {
        log.error("Unexpected error during connection test for {}", getName(), e);
        throw new ConnectorException(
            "Unexpected error during connection test: " + e.getMessage(),
            e,
            ConnectorException.ErrorType.CONNECTION_ERROR);
    }
}

/**
 * Extract connection properties from the map.
 * Properties are passed as a map when init() is called.
 */
private void extractConnectionProperties(Map<String, Object> props) {
    this.clientId = (String) props.get("clientId");
    this.clientSecret = (String) props.get("clientSecret");
    this.subdomain = (String) props.get("subdomain");
    this.accountId = (String) props.get("accountId");
    this.historicalSyncStartDate = (String) props.get("historicalSyncStartDate");
    // Extract other properties...
}

/**
 * Validate required properties are set.
 */
private void validateProperties() throws ConnectorException {
    List<String> missing = new ArrayList<>();

    if (clientId == null || clientId.isEmpty()) {
        missing.add("clientId");
    }
    if (clientSecret == null || clientSecret.isEmpty()) {
        missing.add("clientSecret");
    }
    if (subdomain == null || subdomain.isEmpty()) {
        missing.add("subdomain");
    }
    // Add other required properties...

    if (!missing.isEmpty()) {
        throw new ConnectorException(
            "Missing required properties: " + String.join(", ", missing),
            ConnectorException.ErrorType.CONFIGURATION_ERROR);
    }
}

/**
 * Create OkHttpClient with proper configuration from runtime context.
 */
private OkHttpClient createHttpClient() {
    OkHttpClient.Builder builder = new OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .writeTimeout(60, TimeUnit.SECONDS);

    // Apply proxy configuration if available from runtime context
    if (runtimeContext != null && runtimeContext.getHttpClientConfig() != null) {
        HttpClientConfig config = runtimeContext.getHttpClientConfig();
        if (config.getProxy() != null) {
            builder.proxy(config.getProxy());
        }
    }

    return builder.build();
}
```

**CRITICAL Changes from Old API:**

1. **TWO methods instead of one**:
   - `setRuntimeContext(ConnectorRuntimeContext)` - Store context (optional, called first)
   - `init(Map<String, Object>)` - Initialize connector AND test connection (required)

2. **Connection properties passed as Map**: Properties come from `connectionProperties` parameter, not class fields

3. **init() returns DatasourceInitResponse**: This method both initializes AND tests the connection

4. **init() failure path**: Throw `ConnectorException` for invalid credentials, permissions, or connectivity issues

5. **ConnectorException not SupaflowException**: Use the correct exception type

---

## Step 5: DatasourceInitResponse Structure

The `init()` method should return a successful `DatasourceInitResponse` when connection validation passes.
For failed validation, throw `ConnectorException` with the correct `ErrorType`.

```java
// Success response
return DatasourceInitResponse.builder()
    .success(true)
    .productName("Salesforce Marketing Cloud")
    .productVersion("API v1")
    .message("Connection successful")
    .build();

// Failure path
throw new ConnectorException(
    "Authentication failed: Invalid credentials",
    ConnectorException.ErrorType.AUTHENTICATION_ERROR);
```

**DatasourceInitResponse Fields:**

| Field | Description | Required | Example |
|-------|-------------|----------|---------|
| `success` | Whether connection succeeded | Yes | `true` |
| `productName` | Product name | No (but recommended) | "Salesforce Marketing Cloud" |
| `productVersion` | Version info | No | "API v1" |
| `message` | Status message | No | "Connection successful" |
| `metadata` | Additional info | No | Custom map of values |

---

## Step 6: Handle Token Refresh for Authorization Code Flow

For connectors using OAuth2 Authorization Code (where frontend handles the flow):

```java
/**
 * For Authorization Code flow, tokens are populated by frontend.
 * Connector must handle refresh when tokens expire.
 */
private String getAccessTokenWithRefresh() throws IOException, ConnectorException {
    // Check if current token is valid
    if (accessToken != null && tokenExpiresAt != null) {
        Instant expiry = Instant.parse(tokenExpiresAt);
        if (Instant.now().plusSeconds(60).isBefore(expiry)) {
            return accessToken;
        }
    }

    // Token expired or missing - try to refresh
    if (refreshToken == null || refreshToken.isEmpty()) {
        throw new ConnectorException(
            "Access token expired and no refresh token available. Please re-authenticate.",
            ConnectorException.ErrorType.AUTHENTICATION_ERROR);
    }

    log.info("Refreshing expired access token");
    refreshAccessToken();
    return accessToken;
}

private void refreshAccessToken() throws IOException, ConnectorException {
    Map<String, String> body = new HashMap<>();
    body.put("grant_type", "refresh_token");
    body.put("refresh_token", refreshToken);
    body.put("client_id", clientId);
    body.put("client_secret", clientSecret);

    Request request = new Request.Builder()
        .url(tokenUrl)
        .header("Content-Type", "application/x-www-form-urlencoded")
        .post(RequestBody.create(buildFormBody(body), MediaType.parse("application/x-www-form-urlencoded")))
        .build();

    try (Response response = httpClient.newCall(request).execute()) {
        if (!response.isSuccessful()) {
            throw new ConnectorException(
                "Token refresh failed. Please re-authenticate.",
                ConnectorException.ErrorType.AUTHENTICATION_ERROR);
        }

        JsonNode tokenResponse = objectMapper.readTree(response.body().string());

        // Update tokens
        accessToken = tokenResponse.get("access_token").asText();
        if (tokenResponse.has("refresh_token")) {
            refreshToken = tokenResponse.get("refresh_token").asText();
        }

        int expiresIn = tokenResponse.get("expires_in").asInt();
        tokenExpiresAt = Instant.now().plusSeconds(expiresIn).toString();
    }
}
```

### OAuth Provider Requirements Checklist (Required)

Before finalizing any OAuth connector:

1. Document exact required scopes in connector properties and design docs.
2. Verify provider-specific auth params needed for refresh-token issuance (for Google connectors: `access_type=offline`, `prompt=consent` when applicable).
3. Validate refresh-token behavior in IT:
   - valid refresh token path works
   - missing/expired refresh token fails with `AUTHENTICATION_ERROR`
4. Ensure token-refresh response updates `refreshToken` when provider rotates it.

---

## Step 7: Implement Rate Limiting with Retry

```java
/**
 * Execute request with retry logic for rate limiting.
 */
private JsonNode executeWithRetry(Request request, int maxRetries) throws IOException {
    int attempt = 0;
    int backoffSeconds = 5;

    while (attempt < maxRetries) {
        try (Response response = httpClient.newCall(request).execute()) {
            if (response.code() == 429) {
                // Rate limited - check Retry-After header
                String retryAfter = response.header("Retry-After");
                int waitSeconds = retryAfter != null
                    ? Integer.parseInt(retryAfter)
                    : backoffSeconds;

                log.warn("Rate limited, waiting {} seconds (attempt {}/{})",
                         waitSeconds, attempt + 1, maxRetries);

                Thread.sleep(waitSeconds * 1000L);
                backoffSeconds = Math.min(backoffSeconds * 2, 300);  // Max 5 min
                attempt++;
                continue;
            }

            if (response.code() == 401) {
                // Token might have expired - refresh and retry
                tokenManager.invalidateToken();
                // Rebuild request with new token on next attempt
                attempt++;
                continue;
            }

            // Handle other errors or return success
            String body = response.body() != null ? response.body().string() : "";
            if (!response.isSuccessful()) {
                throw new ConnectorException(
                    "HTTP " + response.code() + ": " + body,
                    ConnectorException.ErrorType.SERVER_ERROR);
            }

            return objectMapper.readTree(body);

        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new ConnectorException("Interrupted during retry", e,
                ConnectorException.ErrorType.INTERRUPTED);
        }
    }

    throw new ConnectorException(
        "Max retries (" + maxRetries + ") exceeded for rate limiting",
        ConnectorException.ErrorType.RATE_LIMIT_EXCEEDED);
}
```

---

## Gate Verification

### Automated Checks

```bash
# 1. Compile the project
cd connectors/supaflow-connector-{name}
mvn compile

# 2. Run verification script
cd ../..
bash <skill-root>/scripts/verify_connector.sh {name} <platform-root>
```

### Expected Verification Results

| Check | Expected Result |
|-------|-----------------|
| CHECK 7 | ✓ Connection management (setRuntimeContext/init) |
| CHECK 10 | ✓ OAuth implementation (if applicable) |
| Previous checks | Still passing |

### Manual Checklist

Before proceeding to Phase 4, confirm ALL of the following:

| Check | Verification |
|-------|--------------|
| ☐ init() validates required properties | Code review |
| ☐ init() creates HTTP client correctly | Code review |
| ☐ init() obtains token successfully | Integration test |
| ☐ init() returns DatasourceInitResponse | Code review |
| ☐ setDatasourceProductName/Version called | Code review |
| ☐ Token caching implemented (not fetching every call) | Code review |
| ☐ Token refresh before expiry (with buffer) | Code review |
| ☐ 401/403 errors throw ConnectorException with AUTHENTICATION_ERROR/PERMISSION_ERROR | Code review |
| ☐ Rate limiting handled with retry | Code review |
| ☐ CHECK 7, 10 pass | Verification script |

### Integration Test

Before proceeding, manually test with real credentials:

```bash
# Set environment variables with your credentials
export {NAME}_CLIENT_ID="your-client-id"
export {NAME}_CLIENT_SECRET="your-client-secret"
export {NAME}_SUBDOMAIN="your-subdomain"

# Run a simple test (you'll create this in Phase 6, but can test manually now)
```

### Show Your Work

Before proceeding to Phase 4, show:

1. Output of `mvn compile`
2. Output of `bash <skill-root>/scripts/verify_connector.sh {name} <platform-root>` (CHECKs 7, 10)
3. Confirmation that init() works with real credentials
4. Token management approach (caching, refresh strategy)

---

## Common Mistakes to Avoid

| Mistake | Why It's Wrong | Correct Approach |
|---------|----------------|------------------|
| Fetching new token every request | Slow, may hit rate limits | Cache token, refresh before expiry |
| Not validating properties in init() | Fails later with confusing errors | Validate early, fail fast |
| Ignoring ConnectorRuntimeContext HTTP config | Proxy settings not applied | Use runtimeContext.getHttpClientConfig() |
| Not setting productName/Version | Missing metadata in connection info | Always set in DatasourceInitResponse |
| Catching all exceptions as ConnectorException | Auth errors not distinguished | Use AUTHENTICATION_ERROR/PERMISSION_ERROR for 401/403 |
| Hardcoding timeouts | Can't adapt to slow networks | Use reasonable defaults, consider config |

---

## Next Phase

Once all gate checks pass, proceed to:
→ **PHASE_4_SCHEMA_DISCOVERY.md**
