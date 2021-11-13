LD = ld

CC = clang
CFLAGS = -march=native -Wall -Wextra -std=c11 -O3 -g

CPP = clang++
CPPFLAGS = -march=native -Wall -Wextra -std=c++17 -O3 -g

.PHONY: all
all: write read fizzbuzz

page-info.o: page-info.c page-info.h
	$(CC) -c $(CFLAGS) $<

%.o: %.cpp common.h
	$(CPP) -c $(CPPFLAGS) -o $@ $<

write: write.o page-info.o
	$(CPP) -o $@ $^

read: read.o page-info.o
	$(CPP) -o $@ $^

fizzbuzz.o: fizzbuzz.S
	# clang doesn't work to compile the assembly
	gcc -c -mavx2 $<

fizzbuzz: fizzbuzz.o
	$(LD) -o $@ $?

.PHONY: clean
clean:
	rm -f *.o
	rm -f write read fizzbuzz
