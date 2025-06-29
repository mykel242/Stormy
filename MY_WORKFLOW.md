  Daily Development:

# Create feature branch
  git checkout -b feature/my-feature

# Make changes, then commit & push
  git add . && git commit -m "Add feature" && git push origin
  feature/my-feature

# Create PR (automatic CI runs)
  gh pr create --title "Feature name"

# After PR is approved and merged
  
  git checkout main
  git pull origin main  # Get the merged changes

# Release Process (when ready to release)
  ./scripts/prepare-release.sh 1.0.4  # You choose the version
  git tag v1.0.4 && git push origin v1.0.4  # Triggers automated release

  # Automated: GitHub creates release with packaged addon

  What happens automatically:
  - Tag push triggers release workflow
  - Workflow packages addon files
  - Creates GitHub release with downloadable .zip
  - Users can install from releases page
  
 # Version Strategy:
  - Manual control - you decide when to bump and by how much
  - Semantic versioning (x.y.z):
    - 1.0.4 → 1.0.5 (patch: bug fixes)
    - 1.0.5 → 1.1.0 (minor: new features)
    - 1.1.0 → 2.0.0 (major: breaking changes)