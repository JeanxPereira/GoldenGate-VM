// Create one compute pipeline from a .spv on the default Vulkan driver; report the result.
//   pipe <file.spv> [nbuffers]   (layout: set 0, bindings 0..n-1 storage buffers)
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#define CK(x) do { VkResult r_ = (x); if (r_) { fprintf(stderr, "%s -> %d\n", #x, r_); return 1; } } while (0)
int main(int argc, char **argv) {
  FILE *f = fopen(argv[1], "rb"); if (!f) return 2;
  fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
  uint32_t *w = malloc(n); if (fread(w, 1, n, f) != (size_t)n) return 2; fclose(f);
  int nb = argc > 2 ? atoi(argv[2]) : 1;
  VkApplicationInfo ai = {VK_STRUCTURE_TYPE_APPLICATION_INFO, 0, "pipe", 0, 0, 0, VK_API_VERSION_1_2};
  VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, 0, 0, &ai};
  VkInstance inst; CK(vkCreateInstance(&ici, 0, &inst));
  uint32_t pc = 8; VkPhysicalDevice pds[8]; CK(vkEnumeratePhysicalDevices(inst, &pc, pds));
  VkPhysicalDeviceProperties pp; vkGetPhysicalDeviceProperties(pds[0], &pp);
  fprintf(stderr, "device: %s\n", pp.deviceName);
  float prio = 1; VkDeviceQueueCreateInfo qci = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, 0, 0, 0, 1, &prio};
  VkPhysicalDeviceVulkan12Features f12 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES};
  VkPhysicalDeviceVulkan11Features f11 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, &f12};
  VkPhysicalDeviceFeatures2 f2 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &f11};
  if (getenv("ALLFEAT")) vkGetPhysicalDeviceFeatures2(pds[0], &f2);
  VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &f2, 0, 1, &qci};
  VkDevice dev; CK(vkCreateDevice(pds[0], &dci, 0, &dev));
  VkShaderModuleCreateInfo smci = {VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, 0, 0, n, w};
  VkShaderModule sm; CK(vkCreateShaderModule(dev, &smci, 0, &sm));
  VkDescriptorSetLayoutBinding b[32];
  for (int i = 0; i < nb; i++) { VkDescriptorSetLayoutBinding x = {i, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, 0}; b[i] = x; }
  VkDescriptorSetLayoutCreateInfo dl = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, 0, 0, nb, b};
  VkDescriptorSetLayout dsl; CK(vkCreateDescriptorSetLayout(dev, &dl, 0, &dsl));
  VkPipelineLayoutCreateInfo pl = {VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, 0, 0, 1, &dsl};
  VkPipelineLayout lay; CK(vkCreatePipelineLayout(dev, &pl, 0, &lay));
  VkComputePipelineCreateInfo cp = {VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};
  cp.stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
  cp.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT; cp.stage.module = sm; cp.stage.pName = "main"; cp.layout = lay;
  VkPipeline p; VkResult r = vkCreateComputePipelines(dev, 0, 1, &cp, 0, &p);
  printf("create_compute_pipelines=%d\n", r);
  return r ? 1 : 0;
}
