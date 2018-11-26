#include <chrono>

#include "example/nbody/soa/configuration.h"
#include "example/nbody/soa/nbody.h"

namespace nbody {

__device__ AllocatorT* device_allocator;
__device__ double device_checksum;

// Host side pointer.
AllocatorHandle<AllocatorT>* allocator_handle;


__DEV__ Body::Body(float pos_x, float pos_y,
                   float vel_x, float vel_y, float mass)
    : pos_x_(pos_x), pos_y_(pos_y),
      vel_x_(vel_x), vel_y_(vel_y), mass_(mass) {}


__DEV__ void Body::compute_force() {
  force_x_ = 0.0f;
  force_y_ = 0.0f;
  device_allocator->template device_do<Body>(&Body::apply_force, this);
}


__DEV__ void Body::apply_force(Body* other) {
  if (other != this) {
    float dx = pos_x_ - other->pos_x_;
    float dy = pos_y_ - other->pos_y_;
    float dist = sqrt(dx*dx + dy*dy);
    float F = kGravityConstant * mass_ * other->mass_ / (dist * dist);
    force_x_ += F*dx / dist;
    force_y_ += F*dy / dist;
  }
}

__DEV__ void Body::update() {
  vel_x_ += force_x_*kDt / mass_;
  vel_y_ += force_y_*kDt / mass_;
  pos_x_ += vel_x_*kDt;
  pos_y_ += vel_y_*kDt;

  if (pos_x_ < -kScalingFactor || pos_x_ > kScalingFactor) {
    vel_x_ = -vel_x_;
  }

  if (pos_y_ < -kScalingFactor || pos_y_ > kScalingFactor) {
    vel_y_ = -vel_y_;
  }
}


__DEV__ void Body::add_checksum() {
  device_checksum += pos_x_ + pos_y_*2 + vel_x_*3 + vel_y_*4;
}


__global__ void kernel_compute_checksum() {
  device_checksum = 0.0f;
  device_allocator->template device_do<Body>(&Body::add_checksum);
}


__global__ void kernel_initialize_bodies() {
  int tid = threadIdx.x + blockDim.x * blockIdx.x;
  curandState rand_state;
  curand_init(kSeed, tid, 0, &rand_state);

  for (int i = tid; i < kNumBodies; i += blockDim.x * gridDim.x) {
    device_allocator->make_new<Body>(
        /*pos_x=*/ kScalingFactor * (2 * curand_uniform(&rand_state) - 1),
        /*pos_y=*/ kScalingFactor * (2 * curand_uniform(&rand_state) - 1),
        /*vel_x=*/ kScalingFactor * (curand_uniform(&rand_state) - 0.5) / 1000,
        /*vel_y=*/ kScalingFactor * (curand_uniform(&rand_state) - 0.5) / 1000,
        /*mass=*/ kScalingFactor * (curand_uniform(&rand_state)/2 + 0.5) * kMaxMass);
  }
}


int main(int argc, char** argv) {
  AllocatorT::DBG_print_stats();

  // Create new allocator.
  allocator_handle = new AllocatorHandle<AllocatorT>();
  AllocatorT* dev_ptr = allocator_handle->device_pointer();
  cudaMemcpyToSymbol(device_allocator, &dev_ptr, sizeof(AllocatorT*), 0,
                     cudaMemcpyHostToDevice);

  auto time_start = std::chrono::system_clock::now();

  kernel_initialize_bodies<<<128, 128>>>();
  gpuErrchk(cudaDeviceSynchronize());

  for (int i = 0; i < kNumIterations; ++i) {
    allocator_handle->parallel_do<Body, &Body::compute_force>();
    allocator_handle->parallel_do<Body, &Body::update>();
  }

  auto time_end = std::chrono::system_clock::now();
  auto elapsed = time_end - time_start;
  auto millis = std::chrono::duration_cast<std::chrono::milliseconds>(elapsed)
      .count();

  printf("Time: %lu ms\n", millis);

  kernel_compute_checksum<<<1, 1>>>();
  gpuErrchk(cudaDeviceSynchronize());

  double checksum;
  cudaMemcpyFromSymbol(&checksum, device_checksum, sizeof(device_checksum), 0,
                       cudaMemcpyDeviceToHost);
  printf("Checksum: %f\n", checksum);

  return 0;
}

}

int main(int argc, char** argv) { return nbody::main(argc, argv); }
