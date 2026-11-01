.PHONY: all src integrate clean

all: src

src:
	$(MAKE) -C src

integrate: src
	$(MAKE) -C ../trials integrate

clean:
	$(MAKE) -C src clean
	$(MAKE) -C ../trials clean
