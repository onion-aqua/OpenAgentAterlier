#include "Live2DAllocator.hpp"

#include <malloc.h>
#include <stdlib.h>

void* Live2DAllocator::Allocate(const Csm::csmSizeType size) {
  return malloc(size);
}

void Live2DAllocator::Deallocate(void* memory) { free(memory); }

void* Live2DAllocator::AllocateAligned(const Csm::csmSizeType size,
                                       const Csm::csmUint32 alignment) {
  return _aligned_malloc(size, alignment);
}

void Live2DAllocator::DeallocateAligned(void* aligned_memory) {
  _aligned_free(aligned_memory);
}
