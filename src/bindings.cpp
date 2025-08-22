#include <stdio.h>
#include <bc7enc/rdo_bc_encoder.h>
#include <bc7enc/utils.h>

#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_FAILURE_STRINGS
#include "stb_image.h"

#define STB_IMAGE_RESIZE_IMPLEMENTATION
#define STBIR_USE_FMA
#include "stb_image_resize2.h"

extern "C" {
	rdo_bc::rdo_bc_encoder * bc7enc_init() {
		return new rdo_bc::rdo_bc_encoder();
	}

	void bc7enc_deinit(rdo_bc::rdo_bc_encoder * encoder) {
		delete encoder;
	}

	bool bc7enc_encode(
		rdo_bc::rdo_bc_encoder * encoder,
		rdo_bc::rdo_bc_params * const params,
		uint32_t width,
		uint32_t height,
		float * const pixels
	) {
		// Encode the image as u8s. We need to do this before initializing the encoder, since doing
		// so may change the perceptual param that we reference here. It's unfortunate that the C++
		// API requires us to do a copy here, but the time it takes to copy an image while not
		// insignificant is dwarfed by the time it takes to encode as BC7.
		utils::image_u8 img;
		img.init(width, height);
		auto &ldr = img.get_pixels();
		for (size_t i = 0; i < (size_t)width * (size_t)height; ++i) {
			utils::color_quad_u8 pixel;
			for (uint8_t channel = 0; channel < 4; ++channel) {
				float sample = pixels[i * 4 + channel];
				if (params->m_perceptual && channel != 3) sample = pow(sample, 1.0f / 2.2f);
				sample = sample * 255.0f + 0.5f;
				if (sample < 0.0f) {
					sample = 0.0f;
				} else if (sample > 255.0f) {
					sample = 255.0f;
				}
				pixel.m_c[channel] = sample;
			}
			ldr[i] = pixel;
		}

		// Encode the data as BC7. This may modify params which is referenced above.
		if (!encoder->init(img, *params)) {
			return false;
		}
		if (!encoder->encode()) return false;
		return true;
	}

	uint8_t * bc7enc_getBlocks(rdo_bc::rdo_bc_encoder * encoder) {
		return (uint8_t *)encoder->get_blocks();
	}

	uint32_t bc7enc_getTotalBlocksSizeInBytes(rdo_bc::rdo_bc_encoder * encoder) {
		return encoder->get_total_blocks_size_in_bytes();
	}
}
