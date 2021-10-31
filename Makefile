CC = clang
LD = ld
CFLAGS = -mavx2 -Wall -Wextra -std=c11 -O3 -g

.PHONY: all
all: vmsplice fizzbuzz

%.o: %.c
	$(CC) -c $(CFLAGS) $<

vmsplice: vmsplice.o page-info.o
	$(CC) -o $@ $^

fizzbuzz.o: fizzbuzz.S
	gcc -c $(CFLAGS) $<

fizzbuzz: fizzbuzz.o
	$(LD) -o $@ $?

.PHONY: clean
clean:
	rm -f *.o
	rm -f vmsplice
	rm -f fizzbuzz
