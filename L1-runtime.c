/**
 * L1 Runtime System
 * Taken mostly from EECS 322 lecture notes
 *
 * @author Robby Findler <robby@eecs.northwestern.edu>
 * @author Geoff Hill <GeoffreyHill2012@u.northwestern.edu>
 */

#include <stdio.h>
#include <stdlib.h>

// cross-platform way to ensure runtime function names
// are exactly this, with no leading underscore
extern very_first_fn () asm ("very_first_fn");
extern int l1_print () asm ("l1_print");
extern void *l1_alloc () asm ("l1_alloc");
extern int l1_arrayerr () asm ("l1_arrayerr");

void print_content(void** in, int depth) {
  if (depth >= 4) {
    printf("...");
    return;
  }
  int x = (int) in;
  if (x&1) {
    printf("%i",x>>1);
  } else {
    int size= *((int*)in);
    void** data = in+1;
    int i;
    printf("{s:%i", size);
    for (i=0;i<size;i++) {
      printf(", ");
      print_content(*data,depth+1);
      data++;
    }
    printf("}");
  }
}

int l1_print(void* l) {
  print_content(l,0);
  printf("\n");
  return 1;
}

#define HEAP_SIZE 8388608  // 8MB

void** heap;
void** allocptr;
int words_allocated=0;

void* l1_alloc(int fw_size, void *fw_fill) {
  int size = fw_size >> 1;
  void** ret = (void**)allocptr;
  int i;

  if (!(fw_size&1)) {
    printf("allocate called with size input that was not an encoded integer, %i\n",
           fw_size);
  }
  if (size < 0) {
    printf("allocate called with size of %i\n",size);
    exit(-1);
  }

  allocptr+=(size+1);
  words_allocated+=(size+1);
  
  if (words_allocated < HEAP_SIZE) {
    *((int*)ret)=size;
    void** data = ret+1;
    for (i=0;i<size;i++) {
      *data = fw_fill;
      data++;
    }
    return ret;
  }
  else {
    printf("out of memory");
    exit(-1);
  }
}

int l1_arrayerr(int* array, int fw_x) {
  printf("attempted to use position %i in an array that only has %i positions\n",
		 fw_x>>1, *array);
  exit(0);
}

int main() {
  heap=(void*)malloc(HEAP_SIZE*sizeof(void*));
  if (!heap) {
    printf("malloc failed\n");
    exit(-1);
  }
  allocptr=heap;
  very_first_fn();   // call into the generated code
 return 0;
}
