using Test
using Lyr
using InteractiveUtils
using JET
using Cthulhu

# Internal symbols imported for unit testing (not part of public API)
import Lyr:
    # Binary read
    read_u8, read_u32_le, read_u64_le, read_i32_le, read_i64_le,
    read_f16_le, read_f32_le, read_f64_le, read_bytes, read_cstring, read_string_with_size,
    # Binary write
    write_u8!, write_u32_le!, write_u64_le!, write_i32_le!, write_i64_le!,
    write_f16_le!, write_f32_le!, write_f64_le!, write_bytes!, write_cstring!, write_string_with_size!,
    write_tile_value!,
    # Compression internals
    Codec, decompress, read_compressed_bytes,
    # Coordinate internals
    leaf_origin, internal1_origin, internal2_origin,
    leaf_offset, internal1_child_index, internal2_child_index,
    # Topology internals
    child_origin_internal2, child_origin_internal1,
    # Values internals
    read_leaf_values, read_tile_value,
    # Parser internals
    read_mask, read_transform, parse_grid_class, read_grid,
    VDB_MAGIC, parse_value_type, read_header, read_grid_descriptor,
    # DDA internals
    DDAState, dda_init, dda_step!, NodeDDA,
    node_dda_init, node_dda_child_index, node_dda_inside, node_dda_voxel_origin,
    # Exception detail types
    InvalidMagicError, ChunkSizeMismatchError, CompressionBoundsError,
    DecompressionSizeError, ValueCountError,
    # Ray internals
    LeafIntersection,
    # Render internals
    camera_ray, sphere_trace, shade,
    # Volume internals
    delta_tracking_step, ratio_tracking,
    # GPU internals
    _gpu_get_value, _gpu_get_value_trilinear,
    _gpu_buf_mask_is_on, _gpu_buf_count_on_before,
    _gpu_buf_load, _gpu_ray_box_intersect, _gpu_xorshift, _gpu_wang_hash,
    _bake_tf_lut, _estimate_density_range,
    # Scene abstract
    AbstractLight,
    # Visualize internals
    _auto_camera

@testset "Lyr.jl" begin
    include("test_binary.jl")
    include("test_masks.jl")
    include("test_coordinates.jl")
    include("test_compression.jl")
    include("test_tree_types.jl")
    include("test_topology.jl")
    include("test_values.jl")
    include("test_tree_read.jl")
    include("test_transforms.jl")
    include("test_staticarrays.jl")
    include("test_grid.jl")
    include("test_file.jl")
    include("test_accessors.jl")
    include("test_interpolation.jl")
    include("test_ray.jl")
    include("test_dda.jl")
    include("test_node_dda.jl")
    include("test_hierarchical_dda.jl")
    include("test_volume_ray_intersector.jl")
    include("test_render.jl")
    include("test_surface.jl")
    include("test_nanovdb.jl")
    include("test_integration.jl")
    include("test_parser_equivalence.jl")
    include("test_writer.jl")
    include("test_grid_builder.jl")
    include("test_transfer_function.jl")
    include("test_phase_function.jl")
    include("test_scene.jl")
    include("test_volume_renderer.jl")
    include("test_gpu.jl")
    include("test_output.jl")
    include("test_show.jl")
    include("test_properties.jl")
    include("test_type_stability.jl")
    include("test_jet.jl")
    include("test_cthulhu.jl")
    include("test_field_protocol.jl")
    include("test_voxelize.jl")
    include("test_visualize.jl")
    include("test_gr_types.jl")
    include("test_gr_metric.jl")
    include("test_gr_schwarzschild.jl")
    include("test_gr_integrator.jl")
    include("test_gr_camera.jl")
    include("test_gr_matter.jl")
    include("test_gr_redshift.jl")
    include("test_gr_render.jl")
    include("test_gr_volumetric.jl")
    include("test_gr_validation.jl")
end
