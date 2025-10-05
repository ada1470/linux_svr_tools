#!/bin/bash
# realtime_io_latency.sh

# while true; do
#   START=$(date +%s%3N)
#   dd if=/dev/zero of=/tmp/test_io_latency_$$ bs=512 count=1 oflag=dsync oflag=direct &> /dev/null
#   END=$(date +%s%3N)
#   echo "IO延迟: $((END - START)) ms"
#   sleep 1
# done


# for i in {1..10}; do
#   START=$(date +%s%3N)
#   dd if=/dev/zero of=/tmp/test_io_$$ bs=512 count=1 oflag=dsync oflag=direct &> /dev/null
#   END=$(date +%s%3N)
#   echo "IO模拟延迟: $((END - START)) ms"
#   sleep 1
# done

#!/bin/bash
# TEST_FILE="/www/server/panel/data/iotest"

# for i in {1..5}; do
#   START=$(date +%s%3N)
#   dd if=/dev/zero of=$TEST_FILE bs=512 count=1 oflag=dsync oflag=direct &> /dev/null
#   END=$(date +%s%3N)
#   echo "Baota-style IO延迟模拟: $((END - START)) ms"
#   sleep 1
# done

for i in {1..5}; do
  start=$(date +%s%3N)
  dd if=/dev/zero of=/www/server/panel/data/iotest.test bs=512 count=1 oflag=dsync 2>/dev/null
  end=$(date +%s%3N)
  delay=$((end - start))
  echo "模拟 IO延迟: ${delay} ms"
  sleep 1
done
