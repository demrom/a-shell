BEGIN {
    for (i = 0; i < 50000000; i++) total += i
    printf "%.0f\n", total
}
