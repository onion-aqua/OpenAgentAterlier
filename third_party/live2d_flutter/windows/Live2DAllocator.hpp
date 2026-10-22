#pragma once

#include <CubismFramework.hpp>
#include <ICubismAllocator.hpp>

class Live2DAllocator : public Csm::ICubismAllocator {
 public:
  void* Allocate(Csm::csmSizeType size) override;
  void Deallocate(void* memory) override;
  void* AllocateAligned(Csm::csmSizeType size,
                        Csm::csmUint32 alignment) override;
  void DeallocateAligned(void* aligned_memory) override;
};
