#!/bin/bash

BASE_URL="http://localhost:8080"

echo "Generating baseline traffic..."

for i in $(seq 1 50); do
  PRODUCT_ID=$((RANDOM % 10 + 1))
  QUANTITY=$((RANDOM % 5 + 1))
  INVENTORY_ID=$((RANDOM % 10 + 1))

  curl -s -X POST "$BASE_URL/api/orders" -H "Content-Type: application/json" -d "{\"product_id\":${PRODUCT_ID},\"quantity\":${QUANTITY}}" > /dev/null

  curl -s "$BASE_URL/api/orders" > /dev/null
  curl -s "$BASE_URL/api/inventory/${INVENTORY_ID}" > /dev/null

  echo "Request $i completed"
  sleep 2
done
