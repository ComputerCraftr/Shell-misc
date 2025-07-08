#!/bin/sh

awk 'BEGIN{RS="</title>"; IGNORECASE=1}
  /<title/ {
    sub(/^.*<title[^>]*>/, "", $0)
    gsub(/[[:space:]]+$/, "", $0)
    gsub(/^[[:space:]]+/, "", $0)
    print
    exit
  }'
