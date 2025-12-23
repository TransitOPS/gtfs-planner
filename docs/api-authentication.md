# API Authentication

This guide explains how to authenticate with the GTFS Planner API using API keys.

## Overview

GTFS Planner uses API key-based authentication for programmatic access to the API. API keys are organization-scoped and support role-based access control, allowing fine-grained permissions for different use cases.

## API Key Creation

### Creating an API Key

API keys are created through the organization's management interface or programmatically by organization administrators.

**Requirements:**

- Must be an organization administrator or have appropriate permissions
- Must belong to an organization

**API Key Structure:**

Each API key consists of:

- **Description**: A human-readable label for the key
- **Roles**: Array of role strings (e.g., `["administrator"]`, `[]`)
- **Version**: Integer version identifier (currently always `1`)
- **Secret Token**: Cryptographically secure random token

**Example API Key:**

```
GtfsPlanner.V1.abcdefghijklmnopqrstuvwxyz1234567890
```

### API Key Management

- Create keys with specific roles for different applications
- Delete keys when they are no longer needed
- Rotate keys periodically for security
- Each key is tied to a specific organization

## Bearer Token Format

GTFS Planner follows RFC 6750 for bearer token authentication.

### Token Format

API keys use the following format:

```
GtfsPlanner.V1.<encoded_token>
```

- **Prefix**: `GtfsPlanner.V1` (fixed)
- **Separator**: `.` (period)
- **Encoded Token**: Base64-encoded binary token

**Example:**

```
GtfsPlanner.V1.YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY3ODkw
```

### Version Identifier

The version number (`V1`) allows for future format changes while maintaining backward compatibility. All current API keys use version 1.

## Authentication Header Format

### RFC 6750 Compliant Format

The standard format uses the `Bearer` authentication scheme:

```http
Authorization: Bearer GtfsPlanner.V1.YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY3ODkw
```

### Compatibility Format

For backward compatibility, the prefix can be used directly:

```http
Authorization: GtfsPlanner.V1.YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY3ODkw
```

### Using with cURL

```bash
curl -H "Authorization: Bearer GtfsPlanner.V1.YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY3ODkw" \
  https://api.gtfsplanner.com/v1/pathways
```

### Using with JavaScript (fetch)

```javascript
fetch("https://api.gtfsplanner.com/v1/pathways", {
  headers: {
    Authorization:
      "Bearer GtfsPlanner.V1.YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY3ODkw",
  },
});
```

### Using with Python (requests)

```python
import requests

headers = {
    'Authorization': 'Bearer GtfsPlanner.V1.YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY3ODkw'
}
response = requests.get('https://api.gtfsplanner.com/v1/pathways', headers=headers)
```

## Error Responses

### Missing API Key

When no `Authorization` header is provided:

**Status:** `401 Unauthorized`

```json
{
  "error": "unauthorized",
  "message": "API key is required"
}
```

### Invalid API Key

When the API key format is incorrect or the token cannot be validated:

**Status:** `401 Unauthorized`

```json
{
  "error": "unauthorized",
  "message": "Invalid API key"
}
```

### Expired or Revoked Key

When the API key has been deleted or is no longer valid:

**Status:** `401 Unauthorized`

```json
{
  "error": "unauthorized",
  "message": "API key not found or has been revoked"
}
```

### Insufficient Permissions

When the API key lacks the required role for an endpoint:

**Status:** `403 Forbidden`

```json
{
  "error": "forbidden",
  "message": "Insufficient permissions for this operation"
}
```

### Organization Not Found

When the organization associated with the API key does not exist:

**Status:** `404 Not Found`

```json
{
  "error": "not_found",
  "message": "Organization not found"
}
```

## Organization Scoping

### URL-Based Scoping

API requests must be scoped to a specific organization using the organization's alias in the URL path:

```
https://api.gtfsplanner.com/organizations/:org_alias/v1/pathways
```

**Example:**

```
https://api.gtfsplanner.com/organizations/transit-agency/v1/pathways
```

### API Key Organization Binding

- Each API key is bound to a specific organization at creation time
- The key can only access resources within its organization
- Requests to other organizations will return `403 Forbidden`

### Header-Based Organization

Some endpoints may support organization specification via headers:

```http
X-Organization-Alias: transit-agency
```

However, URL-based scoping is the preferred method.

## Role-Based Access

### Supported Roles

GTFS Planner supports the following roles:

- **`administrator`**: Full administrative access, including user management and API key creation
- **`user`**: Standard user access for read/write operations
- **`viewer`**: Read-only access to organization resources
- **`nil`**: Any member of the organization (no specific role required)

### Role Specifications

Roles can be specified in the following formats:

#### Single Role

```elixir
roles: ["administrator"]
```

Requires the API key to have exactly the `administrator` role.

#### Any Role (Membership Only)

```elixir
roles: nil
```

Requires the API key to belong to the organization but doesn't enforce specific roles.

#### Any of Multiple Roles

```elixir
roles: {:any, ["administrator", "user"]}
```

Requires the API key to have at least one of the specified roles.

#### All Required Roles

```elixir
roles: {:all, ["administrator", "moderator"]}
```

Requires the API key to have all specified roles.

### API Key Role Assignment

When creating an API key, assign roles based on the intended use case:

**Administrator Key:**

```elixir
%{description: "Admin automation", roles: ["administrator"]}
```

**User Key:**

```elixir
%{description: "Standard access", roles: ["user"]}
```

**Viewer Key:**

```elixir
%{description: "Read-only dashboard", roles: ["viewer"]}
```

**Member Key:**

```elixir
%{description: "Basic member access", roles: []}
```

### Endpoint Role Requirements

Different API endpoints have different role requirements:

| Endpoint                             | Required Role       | Description               |
| ------------------------------------ | ------------------- | ------------------------- |
| `/pathways`                          | `["user"]`          | Read/write pathways       |
| `/pathways/:id`                      | `["viewer"]`        | Read specific pathway     |
| `/organizations/:org_alias/users`    | `["administrator"]` | Manage organization users |
| `/organizations/:org_alias/api_keys` | `["administrator"]` | Manage API keys           |

## Security Best Practices

### Key Storage

- Never commit API keys to version control
- Store API keys in environment variables or secret management systems
- Use `.env` files (excluded from git) for local development
- Rotate keys if they may have been compromised

**Example Environment Configuration:**

```bash
export GTFS_PLANNER_API_KEY="GtfsPlanner.V1.YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY3ODkw"
```

### Key Rotation

- Rotate keys periodically (e.g., every 90 days)
- Create a new key before deleting the old one
- Update all applications using the old key
- Delete the old key after confirming the new key works

### Least Privilege

- Create separate keys for different applications
- Assign only the minimum roles required for each use case
- Use viewer keys for read-only operations
- Use user keys for standard operations
- Restrict administrator keys to management operations

### Monitoring

- Monitor API key usage in logs
- Set up alerts for unusual activity patterns
- Review and audit key access regularly
- Revoke unused keys immediately

## Implementation Details

### Token Validation

The API authentication process follows these steps:

1. **Extract Token**: Parse the `Authorization` header to extract the API key
2. **Validate Format**: Verify the key matches the expected `GtfsPlanner.V1.*` pattern
3. **Decode Token**: Base64-decode the token portion
4. **Hash Lookup**: Compute SHA3-512 hash and search database
5. **Constant-Time Compare**: Use timing-attack-resistant comparison
6. **Random Delay**: Sleep 500-800ms on failed auth to prevent enumeration
7. **Load Organization**: Fetch the organization associated with the API key
8. **Check Roles**: Verify the key has required roles for the endpoint

### Rate Limiting

Failed authentication attempts include a random delay (500-800ms) to:

- Prevent timing attacks
- Slow down brute force attempts
- Protect against API key enumeration

### Token Hashing

API keys are never stored in plaintext. The validation process:

1. Generate random 32-byte secret token
2. Compute SHA3-512 hash: `hash = :crypto.hash(:sha512, token)`
3. Store hash in database
4. On validation: compute hash of incoming token and compare to stored hash

This ensures that even a database compromise cannot reveal actual API keys.

## Testing Authentication

### Testing with cURL

```bash
# Valid API key
curl -H "Authorization: Bearer GtfsPlanner.V1.YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY3ODkw" \
  https://api.gtfsplanner.com/organizations/transit-agency/v1/pathways

# Invalid API key (should return 401)
curl -H "Authorization: Bearer invalid_key" \
  https://api.gtfsplanner.com/organizations/transit-agency/v1/pathways

# Missing header (should return 401)
curl https://api.gtfsplanner.com/organizations/transit-agency/v1/pathways
```

### Testing with Postman

1. Create a new request
2. Add `Authorization` header with value `Bearer GtfsPlanner.V1.YOUR_KEY`
3. Set the URL to the desired endpoint
4. Send request and verify response

## Troubleshooting

### Common Issues

**401 Unauthorized**

- Verify the API key format is correct: `GtfsPlanner.V1.*`
- Check that the key hasn't been deleted or revoked
- Ensure the `Authorization` header is properly formatted

**403 Forbidden**

- Confirm the API key has the required roles for the endpoint
- Verify the organization alias in the URL matches the key's organization
- Check that your organization membership is active

**404 Not Found**

- Verify the organization alias is correct
- Ensure the organization exists and is active

### Debug Tips

1. **Verify Token Format**: Check that your token starts with `GtfsPlanner.V1.`
2. **Check Headers**: Ensure the `Authorization` header is spelled correctly
3. **Test Organization Alias**: Confirm the organization exists and you have access
4. **Review Logs**: Check application logs for detailed error messages
5. **Test Locally**: Use the development environment to test authentication flows

## Additional Resources

- [Authentication Guide](docs/authentication-guide.md) - Complete authentication system documentation
- [User Management](docs/user-management.md) - Managing users and organizations
- [Engineering Standards](docs/elixir-phoenix-standards.md) - Development guidelines

## Support

For issues with API authentication:

- Review this documentation for common solutions
- Check the application logs for detailed error messages
- Contact the GTFS Planner development team for further assistance
