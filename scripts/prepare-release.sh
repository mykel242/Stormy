#!/bin/bash

# Release Preparation Script for Stormy WoW Addon
# Handles version bumping with cross-platform compatibility

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if version argument is provided
if [ $# -eq 0 ]; then
    print_error "Usage: $0 <version>"
    print_error "Example: $0 1.0.3"
    exit 1
fi

NEW_VERSION="$1"

# Validate version format (basic check)
if [[ ! "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    print_error "Version must be in format x.y.z (e.g., 1.0.3)"
    exit 1
fi

# Check if STORMY.toc exists
if [ ! -f "STORMY.toc" ]; then
    print_error "STORMY.toc not found in current directory"
    exit 1
fi

print_status "Preparing release for version $NEW_VERSION"

# Get current version from TOC file
CURRENT_VERSION=$(grep "^## Version:" STORMY.toc | sed 's/^## Version: //')
print_status "Current version: $CURRENT_VERSION"

# Check if we're on main branch
if command -v git >/dev/null 2>&1; then
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if [ "$CURRENT_BRANCH" != "main" ]; then
        print_warning "You are on branch '$CURRENT_BRANCH', not 'main'"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_error "Aborted"
            exit 1
        fi
    fi
fi

# Update version in STORMY.toc
print_status "Updating version in STORMY.toc"

# Cross-platform sed command
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    sed -i '' "s/^## Version: .*/## Version: $NEW_VERSION/" STORMY.toc
else
    # Linux/Unix
    sed -i "s/^## Version: .*/## Version: $NEW_VERSION/" STORMY.toc
fi

# Verify the change
NEW_VERSION_CHECK=$(grep "^## Version:" STORMY.toc | sed 's/^## Version: //')
if [ "$NEW_VERSION_CHECK" != "$NEW_VERSION" ]; then
    print_error "Failed to update version in STORMY.toc"
    exit 1
fi

print_status "Version updated successfully: $CURRENT_VERSION → $NEW_VERSION"

# Git operations (if git is available)
if command -v git >/dev/null 2>&1; then
    print_status "Checking git status"
    
    # Check if there are uncommitted changes other than STORMY.toc
    if git diff --name-only | grep -v "STORMY.toc" | grep -q .; then
        print_warning "You have uncommitted changes besides STORMY.toc:"
        git diff --name-only | grep -v "STORMY.toc"
        read -p "Continue with release preparation? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_error "Aborted"
            exit 1
        fi
    fi
    
    # Add and commit the version change
    print_status "Committing version bump"
    git add STORMY.toc
    git commit -m "Bump version to $NEW_VERSION

🤖 Generated with [Claude Code](https://claude.ai/code)

Co-Authored-By: Claude <noreply@anthropic.com>"
    
    # Push to origin
    print_status "Pushing to origin"
    git push origin main
    
    print_status "Release preparation complete!"
    echo
    print_status "Next steps:"
    echo "1. Create and push a git tag: git tag v$NEW_VERSION && git push origin v$NEW_VERSION"
    echo "2. The release workflow will automatically trigger"
    
else
    print_warning "Git not found - skipped git operations"
    print_status "Version bump complete. Please manually commit and tag the release."
fi

echo
print_status "Done! ✅"