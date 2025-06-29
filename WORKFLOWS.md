# Stormy GitHub Actions Workflows Guide

This guide explains the GitHub Actions workflows set up for the Stormy addon project.

## Overview

The project has 6 automated workflows:

1. **Unit Tests** - Runs on every push and PR
2. **Lua Linting** - Code quality checks
3. **TOC Validation** - Validates addon manifest
4. **Package Addon** - Creates distributable packages
5. **Release** - Automated release process
6. **Claude Code Review** - AI-powered PR reviews (existing)

## Workflow Details

### 1. Unit Tests (`test.yml`)

**Triggers:** Push to main, Pull requests

**What it does:**
- Runs unit tests using busted framework
- Tests against Lua 5.1 (WoW's version) and 5.4
- Generates coverage reports
- Shows test results in PR summary

**Local testing:**
```bash
# Install dependencies
luarocks install busted
luarocks install luacov

# Run tests
busted -v tests/

# Run with coverage
busted -v --coverage tests/
```

### 2. Lua Linting (`lint.yml`)

**Triggers:** Push to main, Pull requests

**What it does:**
- Runs luacheck for static code analysis
- Checks for common Lua errors
- Validates WoW API usage
- Annotates files with issues

**Local linting:**
```bash
# Install luacheck
luarocks install luacheck

# Run linting
luacheck .
```

### 3. TOC Validation (`validate-toc.yml`)

**Triggers:** Changes to .toc files

**What it does:**
- Validates TOC file structure
- Checks required fields (Interface, Title, Version, Author)
- Verifies all referenced files exist
- Analyzes load order

### 4. Package Addon (`package.yml`)

**Triggers:** 
- Push tags starting with 'v' or 'release-'
- Manual trigger with version input

**What it does:**
- Updates version in TOC file
- Creates clean addon package
- Excludes development files
- Generates checksums (SHA256, MD5)
- Uploads as artifact

**Manual packaging:**
```bash
# Tag a release
git tag v1.0.1
git push origin v1.0.1

# Or use GitHub UI: Actions → Package Addon → Run workflow
```

### 5. Release (`release.yml`)

**Triggers:**
- Push tags starting with 'v'
- Manual trigger with version input

**What it does:**
- Runs all tests first
- Creates packaged addon
- Generates changelog from commits
- Creates GitHub release
- Uploads addon zip with checksums

**Creating a release:**
```bash
# Create and push a version tag
git tag v1.0.1 -m "Release version 1.0.1"
git push origin v1.0.1

# Or use GitHub UI: Actions → Release → Run workflow
```

## Development Workflow

### 1. Regular Development

```bash
# Make changes
git add .
git commit -m "Add new feature"
git push

# Workflows run automatically:
# - Unit tests ✓
# - Linting ✓
# - TOC validation (if .toc changed) ✓
```

### 2. Pull Request

When you create a PR:
- All tests run automatically
- Claude reviews the code
- Linting results appear as annotations
- Test coverage shown in PR summary

### 3. Creating a Release

```bash
# 1. Update version in STORMY.toc
sed -i 's/## Version: .*/## Version: 1.0.1/' STORMY.toc

# 2. Commit changes
git add STORMY.toc
git commit -m "Bump version to 1.0.1"

# 3. Create and push tag
git tag v1.0.1 -m "Release v1.0.1"
git push origin main
git push origin v1.0.1

# Release workflow automatically:
# - Runs tests
# - Creates package
# - Generates changelog
# - Creates GitHub release
```

## Configuration Files

### `.luacheckrc`
- Configures Lua linting rules
- Defines WoW API globals
- Sets code style preferences

### `.busted`
- Test runner configuration
- Defines test file patterns
- Sets test directory

### `.pkgmeta`
- Package configuration
- Defines files to exclude
- Used by packaging workflow

## Best Practices

1. **Before Committing:**
   - Run tests locally: `busted tests/`
   - Check linting: `luacheck .`

2. **Version Numbering:**
   - Use semantic versioning: MAJOR.MINOR.PATCH
   - Tag format: `v1.0.1`

3. **Release Notes:**
   - Commits between tags become changelog
   - Write clear commit messages

4. **Testing:**
   - Add tests for new features
   - Keep test coverage high
   - Mock WoW APIs properly

## Troubleshooting

### Tests Failing
```bash
# Run specific test
busted tests/Core/TablePool_spec.lua

# Run with verbose output
busted -v tests/
```

### Linting Issues
```bash
# See all issues
luacheck . --formatter plain

# Check specific file
luacheck Core/TablePool.lua
```

### Package Issues
- Check `.pkgmeta` for ignore patterns
- Verify all files in TOC exist
- Ensure no development files included

## GitHub Secrets

No secrets required for current workflows. If adding CurseForge upload:
- Add `CURSEFORGE_API_TOKEN` secret
- Add `CURSEFORGE_PROJECT_ID` secret

## Badges

Add to README.md:
```markdown
![Tests](https://github.com/mykel242/Stormy/workflows/Unit%20Tests/badge.svg)
![Linting](https://github.com/mykel242/Stormy/workflows/Lua%20Linting/badge.svg)
```