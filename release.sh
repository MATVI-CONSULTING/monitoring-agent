#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if gh CLI is installed
if ! command -v gh &> /dev/null; then
    print_error "GitHub CLI (gh) is not installed"
    print_info "Install it with: brew install gh"
    exit 1
fi

# Check if we're authenticated
if ! gh auth status &> /dev/null; then
    print_error "Not authenticated with GitHub"
    print_info "Run: gh auth login"
    exit 1
fi

# Check if we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    print_error "Not in a git repository"
    exit 1
fi

# Check for uncommitted changes
if ! git diff-index --quiet HEAD --; then
    print_warning "You have uncommitted changes"
    read -p "Do you want to continue? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Get current branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
print_info "Current branch: $CURRENT_BRANCH"

# Ask for version number
echo
read -p "Enter version number (e.g., 1.0.0): " VERSION

# Validate version format
if [[ ! $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    print_error "Invalid version format. Please use semantic versioning (e.g., 1.0.0)"
    exit 1
fi

TAG="v$VERSION"

# Check if tag already exists
if git rev-parse "$TAG" >/dev/null 2>&1; then
    print_error "Tag $TAG already exists"
    exit 1
fi

# Ask for release notes
echo
print_info "Enter release notes (press Ctrl+D when done):"
RELEASE_NOTES=$(cat)

# Confirm release creation
echo
print_info "Summary:"
echo "  - Version: $VERSION"
echo "  - Tag: $TAG"
echo "  - Branch: $CURRENT_BRANCH"
echo "  - Release notes: "
echo "$RELEASE_NOTES" | sed 's/^/    /'
echo

read -p "Create release? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_info "Release cancelled"
    exit 0
fi

# Pull latest changes
print_info "Pulling latest changes..."
git pull origin "$CURRENT_BRANCH"

# Create and push tag
print_info "Creating tag $TAG..."
git tag -a "$TAG" -m "Release $VERSION"

print_info "Pushing tag to GitHub..."
git push origin "$TAG"

# Create GitHub release
print_info "Creating GitHub release..."
echo "$RELEASE_NOTES" | gh release create "$TAG" \
    --title "Release $VERSION" \
    --notes-file -

print_info "✓ Release $VERSION created successfully!"
print_info "The GitHub Action will now build and publish the Docker image."

# Merge helm-chart into gh-pages
print_info "Merging helm-chart branch into gh-pages..."
ORIGINAL_BRANCH="$CURRENT_BRANCH"

# Fetch latest changes
git fetch origin

# Checkout gh-pages
git checkout gh-pages
git pull origin gh-pages

# Merge helm-chart into gh-pages
git merge origin/helm-chart -m "Merge helm-chart for release $VERSION"

# Push to gh-pages
git push origin gh-pages

# Return to original branch
git checkout "$ORIGINAL_BRANCH"

print_info "✓ Successfully merged helm-chart into gh-pages"

print_info ""
print_info "View release: $(gh release view "$TAG" --web 2>&1 | grep -o 'https://.*')"
print_info "Image will be available at: ghcr.io/$(gh repo view --json nameWithOwner -q .nameWithOwner | tr '[:upper:]' '[:lower:]'):$VERSION"
