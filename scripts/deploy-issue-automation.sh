#!/bin/bash
set -euo pipefail

# Deploy Coder Issue Automation to GitHub repositories
# Usage: ./deploy-issue-automation.sh [repo1] [repo2] [repo3]...
# Example: ./deploy-issue-automation.sh shadowscout stellarscout

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_FILE="$SCRIPT_DIR/../.github/workflows/coder-issue-automation.yaml"
GITHUB_ORG="${GITHUB_ORG:-nyc-design}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_dependencies() {
    log_info "Checking dependencies..."

    if ! command -v gh &> /dev/null; then
        log_error "GitHub CLI (gh) is not installed"
        echo "Install from: https://cli.github.com/"
        exit 1
    fi

    if ! command -v git &> /dev/null; then
        log_error "git is not installed"
        exit 1
    fi

    # Check if gh is authenticated
    if ! gh auth status &> /dev/null; then
        log_error "GitHub CLI is not authenticated"
        echo "Run: gh auth login"
        exit 1
    fi

    log_success "All dependencies are installed"
}

check_workflow_file() {
    if [ ! -f "$WORKFLOW_FILE" ]; then
        log_error "Workflow file not found: $WORKFLOW_FILE"
        exit 1
    fi
    log_success "Found workflow file"
}

create_labels() {
    local repo=$1
    log_info "Creating labels in $repo..."

    # Define labels
    declare -A LABELS=(
        ["coder-claude"]="7B5AFF"
        ["coder-codex"]="10A37F"
        ["coder-gemini"]="4285F4"
    )

    for label in "${!LABELS[@]}"; do
        color="${LABELS[$label]}"

        if gh label list --repo "$GITHUB_ORG/$repo" | grep -q "^$label"; then
            log_warning "Label '$label' already exists in $repo"
        else
            gh label create "$label" \
                --repo "$GITHUB_ORG/$repo" \
                --color "$color" \
                --description "Dispatch to Coder AI agent: ${label#coder-}" \
                2>/dev/null && log_success "Created label '$label' in $repo" \
                || log_warning "Failed to create label '$label' in $repo"
        fi
    done
}

deploy_to_repo() {
    local repo=$1
    local temp_dir=$(mktemp -d)

    log_info "Deploying to $GITHUB_ORG/$repo..."

    # Clone the repository
    log_info "Cloning $repo..."
    if ! gh repo clone "$GITHUB_ORG/$repo" "$temp_dir/$repo" -- --depth 1; then
        log_error "Failed to clone $repo"
        rm -rf "$temp_dir"
        return 1
    fi

    cd "$temp_dir/$repo"

    # Create workflows directory if it doesn't exist
    mkdir -p .github/workflows

    # Copy workflow file
    log_info "Copying workflow file..."
    cp "$WORKFLOW_FILE" .github/workflows/coder-issue-automation.yaml

    # Check if there are changes
    if git diff --quiet .github/workflows/coder-issue-automation.yaml; then
        log_warning "No changes to workflow file in $repo"
    else
        # Commit and push
        git add .github/workflows/coder-issue-automation.yaml
        git commit -m "Add Coder issue automation workflow

This workflow enables automated issue resolution using Coder AI agents.

- Triggers on issue labels: coder-claude, coder-codex, coder-gemini
- Creates or reuses Coder workspaces
- Dispatches tasks to AI agents
- AI agents create PRs automatically

See: https://github.com/nyc-design/Coder-Workspaces/blob/main/CODER_ISSUE_AUTOMATION.md"

        log_info "Pushing changes to $repo..."
        if git push; then
            log_success "Successfully deployed to $repo"
        else
            log_error "Failed to push to $repo"
            cd - > /dev/null
            rm -rf "$temp_dir"
            return 1
        fi
    fi

    # Create labels
    create_labels "$repo"

    # Cleanup
    cd - > /dev/null
    rm -rf "$temp_dir"

    log_success "Completed deployment to $repo"
    return 0
}

check_secrets() {
    local repo=$1
    log_info "Checking secrets for $repo..."

    # Note: gh CLI cannot read secret values, only check if they exist
    # We'll just remind the user to set them

    echo ""
    log_warning "⚠️  Please ensure these secrets are set for $GITHUB_ORG/$repo:"
    echo "   - CODER_URL"
    echo "   - CODER_SESSION_TOKEN"
    echo ""
    echo "   Set them at: https://github.com/$GITHUB_ORG/$repo/settings/secrets/actions"
    echo ""
}

print_usage() {
    cat << EOF
Deploy Coder Issue Automation to GitHub Repositories

Usage:
    $0 [OPTIONS] <repo1> [repo2] [repo3]...

Options:
    -h, --help          Show this help message
    -o, --org ORG       GitHub organization (default: nyc-design)
    --skip-labels       Skip label creation
    --dry-run           Show what would be done without making changes

Examples:
    # Deploy to single repo
    $0 shadowscout

    # Deploy to multiple repos
    $0 shadowscout stellarscout my-other-repo

    # Deploy with custom organization
    $0 -o my-org my-repo

    # Dry run to preview changes
    $0 --dry-run shadowscout

Environment Variables:
    GITHUB_ORG          Default GitHub organization (default: nyc-design)

Prerequisites:
    - GitHub CLI (gh) installed and authenticated
    - Write access to target repositories
    - Workflow file exists at: .github/workflows/coder-issue-automation.yaml

After deployment, configure these secrets in each repository:
    - CODER_URL: Your Coder deployment URL
    - CODER_SESSION_TOKEN: Long-lived Coder session token

For more information:
    https://github.com/nyc-design/Coder-Workspaces/blob/main/CODER_ISSUE_AUTOMATION.md
EOF
}

main() {
    local repos=()
    local skip_labels=false
    local dry_run=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                print_usage
                exit 0
                ;;
            -o|--org)
                GITHUB_ORG="$2"
                shift 2
                ;;
            --skip-labels)
                skip_labels=true
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            *)
                repos+=("$1")
                shift
                ;;
        esac
    done

    # Check if repos provided
    if [ ${#repos[@]} -eq 0 ]; then
        log_error "No repositories specified"
        echo ""
        print_usage
        exit 1
    fi

    # Header
    echo ""
    echo "╔════════════════════════════════════════════════════════╗"
    echo "║        Coder Issue Automation Deployment Tool         ║"
    echo "╚════════════════════════════════════════════════════════╝"
    echo ""

    if [ "$dry_run" = true ]; then
        log_warning "DRY RUN MODE - No changes will be made"
        echo ""
    fi

    # Check dependencies
    check_dependencies
    check_workflow_file

    echo ""
    log_info "Organization: $GITHUB_ORG"
    log_info "Repositories: ${repos[*]}"
    log_info "Skip labels: $skip_labels"
    echo ""

    # Confirm
    if [ "$dry_run" = false ]; then
        read -p "Continue with deployment? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Deployment cancelled"
            exit 0
        fi
        echo ""
    fi

    # Deploy to each repo
    local success_count=0
    local fail_count=0

    for repo in "${repos[@]}"; do
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        if [ "$dry_run" = true ]; then
            log_info "Would deploy to $GITHUB_ORG/$repo"
            if [ "$skip_labels" = false ]; then
                log_info "Would create labels: coder-claude, coder-codex, coder-gemini"
            fi
            ((success_count++))
        else
            if deploy_to_repo "$repo"; then
                check_secrets "$repo"
                ((success_count++))
            else
                ((fail_count++))
            fi
        fi

        echo ""
    done

    # Summary
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log_info "Deployment Summary:"
    log_success "  Successful: $success_count"
    if [ $fail_count -gt 0 ]; then
        log_error "  Failed: $fail_count"
    fi
    echo ""

    if [ "$dry_run" = false ] && [ $success_count -gt 0 ]; then
        log_info "Next steps:"
        echo "  1. Configure secrets (CODER_URL, CODER_SESSION_TOKEN) in each repo"
        echo "  2. Create an issue and add a coder-* label to test"
        echo "  3. Monitor the Actions tab for workflow execution"
        echo ""
        log_info "Documentation:"
        echo "  https://github.com/nyc-design/Coder-Workspaces/blob/main/CODER_ISSUE_AUTOMATION.md"
        echo ""
    fi
}

main "$@"
