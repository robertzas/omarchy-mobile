#!/bin/sh
# SPDX-License-Identifier: MIT
# Unread notifications, reviews waiting on you and your open pull requests,
# as one line of JSON, through the GitHub CLI's own login. From
# simonschubert/github in Simon Schubert's omarchy-widgets (MIT; see README.md).
command -v gh >/dev/null 2>&1 || { echo '{"missing": "gh"}'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo '{"missing": "jq"}'; exit 0; }
gh auth status >/dev/null 2>&1 || { echo '{"auth": false}'; exit 0; }
jq -nc \
  --argjson unread "$(gh api notifications --jq length)" \
  --argjson reviews "$(gh search prs --review-requested=@me --state=open --json number --jq length)" \
  --argjson mine "$(gh search prs --author=@me --state=open --limit 8 --json title,url,repository,updatedAt)" \
  '{auth: true, unread: $unread, reviews: $reviews, mine: [$mine[] | {title, url, repo: .repository.name}]}'
