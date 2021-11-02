CC = clang
LD = ld
CFLAGS = -mavx2 -Wall -Wextra -std=c11 -O3 -g $(OPTIONS_CFLAGS)

.PHONY: all
all: write read fizzbuzz

%.o: %.c common.h
	$(CC) -c $(CFLAGS) $<

write: write.o page-info.o
	$(CC) -o $@ $^

read: read.o
	$(CC) -o $@ $^

fizzbuzz.o: fizzbuzz.S
	# clang doesn't work to compile the assembly
	gcc -c -mavx2 $<

fizzbuzz: fizzbuzz.o
	$(LD) -o $@ $?

.PHONY: clean
clean:
	rm -f *.o
	rm -f write read fizzbuzz
