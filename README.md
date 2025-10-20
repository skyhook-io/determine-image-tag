# Determine Image Tag Action

A GitHub Action that generates consistent, unique image tags for container builds and releases. It supports multiple tag formats and handles duplicate prevention through automatic counters.

## Features

- **Multiple Tag Formats**: Choose from various tag formats to suit your workflow
- **Duplicate Prevention**: Automatically adds counters to ensure unique tags
- **Branch Normalization**: Converts branch names to valid tag formats
- **Length Limits**: Respects Kubernetes' 63-character limit for labels
- **Custom Tags**: Option to override with custom tag values
- **Pull Request Support**: Correctly handles PR branch names

## Usage

### Basic Usage

```yaml
- name: Determine Image Tag
  uses: koalaops/determine-image-tag@v1
  id: tag
  with:
    service_name: my-service

- name: Build and Push Docker Image
  run: |
    docker build -t ${{ steps.tag.outputs.tag }} .
    docker push ${{ steps.tag.outputs.tag }}
```

### Advanced Usage with Custom Format

```yaml
- name: Generate Tag for Production
  uses: koalaops/determine-image-tag@v1
  id: tag
  with:
    service_name: api-gateway
    tag_format: service-date-branch-counter
    max_length: 50
    include_counter: true
```

### Using Custom Tag

```yaml
- name: Use Custom Tag
  uses: koalaops/determine-image-tag@v1
  id: tag
  with:
    custom_tag: v1.2.3-release
```

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `service_name` | Service name to include in tag | No | `""` |
| `custom_tag` | Custom tag to use instead of auto-generation | No | `""` |
| `tag_format` | Tag format (see formats below) | No | `service-date-branch-counter` |
| `max_length` | Maximum tag length | No | `63` |
| `include_counter` | Whether to include counter for duplicates | No | `true` |
| `branch_ref` | Git branch reference | No | `github.ref` |
| `pull_request_ref` | Pull request head ref | No | `github.event.pull_request.head.ref` |
| `working_directory` | Working directory where the git repository is located | No | `.` |
| `branch_separator` | Character to replace special characters in branch names | No | `-` |

### Tag Formats

The action generates tags in different formats based on your needs:

#### `service-date-branch-counter` (default)
- **With service_name**: `{service}_{date}_{branch}_{counter}`
  - Example: `api-gateway_2024-01-15_main_00`
- **Without service_name**: `{date}_{branch}_{counter}`
  - Example: `2024-01-15_main_00`

#### `service-branch-date-counter`
- **With service_name**: `{service}_{branch}_{date}_{counter}`
  - Example: `api-gateway_main_2024-01-15_00`
- **Without service_name**: `{branch}_{date}_{counter}`
  - Example: `main_2024-01-15_00`

#### `branch-date-counter`
- Format: `{branch}_{date}_{counter}`
- Example: `feature-login_2024-01-15_00`
- Example: `main_2024-01-15_03`

#### `branch-date`
- Format: `{branch}_{date}` (no counter)
- Example: `main_2024-01-15`
- Example: `feature-xyz_2024-01-15`

#### `date-branch`
- Format: `{date}_{branch}` (no counter)
- Example: `2024-01-15_develop`
- Example: `2024-01-15_feature-xyz`

**Notes:**
- Dates are always in `YYYY-MM-DD` format
- Counters are 2-digit zero-padded numbers (00, 01, 02, etc.)
- Branch names have special characters (`/`, `:`, `@`, `#`) replaced with `branch_separator` (default: `-`)
- Tags are truncated if they exceed `max_length` (default: 63 characters)
- All tag formats support both dash (`-`) and underscore (`_`) separators (e.g., `branch-date` and `branch_date` are equivalent)
- At least 10 chars are reserved for branch names, in case of very long service names

## Outputs

| Output | Description |
|--------|-------------|
| `tag` | The generated image tag |
| `commit_hash` | The current git commit hash |
| `branch` | The normalized branch name |

## Tag Generation Examples

Here are examples showing exactly what tags will be generated with different inputs:

### Default Configuration
```yaml
- uses: koalaops/determine-image-tag@v1
  # No inputs provided
```
**Result**: `2024-01-15_main_00` (assuming main branch, first build of the day)

### With Service Name
```yaml
- uses: koalaops/determine-image-tag@v1
  with:
    service_name: api-gateway
```
**Result**: `api-gateway_2024-01-15_main_00`

### Feature Branch
```yaml
- uses: koalaops/determine-image-tag@v1
  with:
    service_name: auth
    # On branch: feature/user-login
```
**Result**: `auth_2024-01-15_feature-user-login_00` (note: `/` replaced with `-`)

### Multiple Builds Same Day
```yaml
# First build
- uses: koalaops/determine-image-tag@v1
  with:
    service_name: web
```
**Result**: `web_2024-01-15_main_00`

```yaml
# Second build (same day)
- uses: koalaops/determine-image-tag@v1
  with:
    service_name: web
```
**Result**: `web_2024-01-15_main_01` (counter incremented)

### Different Tag Formats
```yaml
# Service-Branch-Date format with counter
- uses: koalaops/determine-image-tag@v1
  with:
    service_name: api
    tag_format: service-branch-date-counter
```
**Result**: `api_main_2024-01-15_00`

```yaml
# Branch-Date format with counter
- uses: koalaops/determine-image-tag@v1
  with:
    tag_format: branch-date-counter
```
**Result**: `main_2024-01-15_00`

```yaml
# Branch-Date format without counter
- uses: koalaops/determine-image-tag@v1
  with:
    tag_format: branch-date
```
**Result**: `main_2024-01-15`

```yaml
# Date-Branch format (no counter)
- uses: koalaops/determine-image-tag@v1
  with:
    tag_format: date-branch
    include_counter: false
```
**Result**: `2024-01-15_main`

```yaml
# Using underscore alias
- uses: koalaops/determine-image-tag@v1
  with:
    tag_format: branch_date_counter
```
**Result**: `main_2024-01-15_00`

### Custom Tag Override
```yaml
- uses: koalaops/determine-image-tag@v1
  with:
    custom_tag: v1.2.3-rc1
```
**Result**: `v1.2.3-rc1` (auto-generation skipped)

### Using Underscore as Branch Separator
```yaml
- uses: koalaops/determine-image-tag@v1
  with:
    service_name: api
    branch_separator: "_"
    # On branch: feature/new-api
```
**Result**: `api_2024-01-15_feature_new_api_00`

## Examples

### Complete CI/CD Pipeline

```yaml
name: Build and Deploy

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Determine Image Tag
        uses: koalaops/determine-image-tag@v1
        id: tag
        with:
          service_name: my-service
          
      - name: Build Docker Image
        run: |
          docker build -t my-registry/${{ steps.tag.outputs.tag }} .
          
      - name: Push to Registry
        run: |
          docker push my-registry/${{ steps.tag.outputs.tag }}
          
      - name: Deploy
        run: |
          kubectl set image deployment/my-service \
            app=my-registry/${{ steps.tag.outputs.tag }}
```

### Multi-Environment Deployment

```yaml
- name: Generate Dev Tag
  uses: koalaops/determine-image-tag@v1
  id: dev-tag
  with:
    service_name: api
    tag_format: branch-date-counter
    
- name: Generate Prod Tag
  if: github.ref == 'refs/heads/main'
  uses: koalaops/determine-image-tag@v1
  id: prod-tag
  with:
    service_name: api
    custom_tag: ${{ github.event.release.tag_name }}
```

### Monorepo with Multiple Services

```yaml
strategy:
  matrix:
    service: [auth, api, worker]
    
steps:
  - name: Generate Tag for ${{ matrix.service }}
    uses: koalaops/determine-image-tag@v1
    id: tag
    with:
      service_name: ${{ matrix.service }}
      
  - name: Build ${{ matrix.service }}
    run: |
      docker build -t registry/${{ matrix.service }}:${{ steps.tag.outputs.tag }} \
        -f services/${{ matrix.service }}/Dockerfile .
```

### Custom Working Directory

```yaml
- name: Checkout to subdirectory
  uses: actions/checkout@v3
  with:
    path: my-repo

- name: Generate Tag
  uses: koalaops/determine-image-tag@v1
  id: tag
  with:
    service_name: my-service
    working_directory: my-repo
```

## How It Works

1. **Branch Detection**: Automatically detects the current branch from GitHub context
2. **Normalization**: Converts special characters in branch names to underscores
3. **Date Generation**: Uses current date in `YYYY-MM-DD` format
4. **Counter Logic**: 
   - Queries remote git tags to count existing tags with the same prefix
   - Falls back to local tags if remote is unavailable
   - Adds a zero-padded counter (00, 01, 02, etc.)
5. **Length Management**: Truncates tag if it exceeds the maximum length while preserving the counter

## Notes

- Tags are normalized to be compatible with Docker and Kubernetes naming requirements
- The action requires git to be available in the runner environment
- When using counters, the action needs access to git tags (either remote or local)
- By default, the action runs in the current directory (`.`) but you can specify a different `working_directory` if your repository is checked out elsewhere

## License

This action is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Support

For issues and feature requests, please use the [GitHub Issues](https://github.com/koalaops/determine-image-tag/issues) page.