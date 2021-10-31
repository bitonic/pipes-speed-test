CC = clang
LD = ld
CFLAGS = -mavx2 -Wall -Wextra -std=c11 -O3 -g

.PHONY: all
all: vmsplice time-pipe fizzbuzz

%.o: %.c common.h
	$(CC) -c $(CFLAGS) $<

vmsplice: vmsplice.o page-info.o
	$(CC) -o $@ $^

time-pipe: time-pipe.o
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
