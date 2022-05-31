.PHONY: all
all: write read get-user-pages

%: %.cpp common.hpp
	clang++ -Wall -Wextra -std=c++17 -O3 -g -o $@ $<

fizzbuzz: fizzbuzz.S
	gcc -mavx2 -c fizzbuzz.S
	ld -o fizzbuzz fizzbuzz.o

.PHONY: clean
clean:
	rm -f write read get-user-pages
