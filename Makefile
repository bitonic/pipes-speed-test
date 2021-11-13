LD = ld

CPP = clang++
CPPFLAGS = -Wall -Wextra -std=c++17 -g

.PHONY: all
all: write read fizzbuzz

write: write.cpp common.h
	$(CPP) $(CPPFLAGS) -o $@ $<

read: read.cpp common.h
	$(CPP) $(CPPFLAGS) -o $@ $<

fizzbuzz.o: fizzbuzz.S
	# clang doesn't work to compile the assembly
	gcc -c -mavx2 $<

fizzbuzz: fizzbuzz.o
	$(LD) -o $@ $?

.PHONY: clean
clean:
	rm -f *.o
	rm -f write read fizzbuzz
