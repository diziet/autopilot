#!/usr/bin/env bats
# Smoke test — verifies the project structure and basic setup.

@test "project directories exist" {
  [ -d "$BATS_TEST_DIRNAME/../bin" ]
  [ -d "$BATS_TEST_DIRNAME/../lib" ]
  [ -d "$BATS_TEST_DIRNAME/../prompts" ]
  [ -d "$BATS_TEST_DIRNAME/../reviewers" ]
  [ -d "$BATS_TEST_DIRNAME/../examples" ]
  [ -d "$BATS_TEST_DIRNAME/../docs" ]
  [ -d "$BATS_TEST_DIRNAME/../tests" ]
}

@test "README.md exists" {
  [ -f "$BATS_TEST_DIRNAME/../README.md" ]
}

@test "Makefile exists" {
  [ -f "$BATS_TEST_DIRNAME/../Makefile" ]
}

@test "CLAUDE.md exists" {
  [ -f "$BATS_TEST_DIRNAME/../CLAUDE.md" ]
}

@test ".gitignore exists" {
  [ -f "$BATS_TEST_DIRNAME/../.gitignore" ]
}
