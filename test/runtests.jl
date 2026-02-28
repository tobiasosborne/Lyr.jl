using Test
using Lyr
using InteractiveUtils
using JET
using Cthulhu

# Non-exported symbols imported for unit testing.
# Public API uses only exported names; everything below is accessible via Lyr.X
# or this explicit import.
import Lyr:
    # Binary read
    read_u8, read_u32_le, read_u64_le, read_i32_le, read_i64_le,
    read_f16_le, read_f32_le, read_f64_le, read_bytes, read_cstring, read_string_with_size,
    # Binary write
    write_u8!, write_u32_le!, write_u64_le!, write_i32_le!, write_i64_le!,
    write_f16_le!, write_f32_le!, write_f64_le!, write_bytes!, write_cstring!, write_string_with_size!,
    write_tile_value!,
    # Binary generic
    read_le,
    # Mask types and functions
    Mask, LeafMask, Internal1Mask, Internal2Mask,
    is_on, is_off, is_empty, is_full,
    count_on, count_off, count_on_before,
    on_indices, off_indices,
    # Coordinates
    BBox, intersects, volume,
    # Compression
    Codec, compress, decompress, read_compressed_bytes,
    NoCompression, BloscCodec, ZipCodec,
    # Coordinate internals
    leaf_origin, internal1_origin, internal2_origin,
    leaf_offset, internal1_child_index, internal2_child_index,
    # Tree types
    AbstractNode, LeafNode, Tile,
    InternalNode1, InternalNode2, RootNode, Tree,
    GridClass, GRID_LEVEL_SET, GRID_FOG_VOLUME, GRID_STAGGERED, GRID_UNKNOWN,
    # Transforms
    AbstractTransform, LinearTransform, UniformScaleTransform,
    index_to_world, world_to_index, world_to_index_float, voxel_size,
    # File structures
    VDBHeader, GridDescriptor, VDBFile,
    # Accessors
    ValueAccessor, active_bounding_box,
    # Interpolation
    NearestInterpolation, sample_nearest,
    # Ray & DDA
    AABB, intersect_bbox, intersect_leaves, intersect_leaves_dda, VolumeRayIntersector,
    # Topology internals
    child_origin_internal2, child_origin_internal1,
    # Values internals
    read_leaf_values, read_tile_value, _read_value,
    # Parser internals
    read_mask, read_transform, parse_grid_class, read_grid,
    VDB_MAGIC, parse_value_type, read_header, read_grid_descriptor,
    # DDA internals
    DDAState, dda_init, dda_step!, NodeDDA,
    node_dda_init, node_dda_child_index, node_dda_inside, node_dda_voxel_origin,
    # Exceptions
    LyrError, ParseError, CompressionError,
    InvalidMagicError, ChunkSizeMismatchError, CompressionBoundsError,
    DecompressionSizeError, ValueCountError, FormatError, UnsupportedVersionError,
    # Metadata internals
    read_grid_metadata, skip_file_metadata,
    # Ray internals
    LeafIntersection,
    # Render internals
    camera_ray, sphere_trace, shade,
    # NanoVDB
    NanoLeafView, NanoI1View, NanoI2View,
    NanoValueAccessor, NanoLeafHit, NanoVolumeRayIntersector,
    nano_origin, nano_is_active, nano_get_value,
    nano_child_count, nano_tile_count, nano_has_child, nano_has_tile,
    nano_child_offset, nano_tile_value,
    nano_background, nano_bbox, nano_root_count, nano_i2_count, nano_i1_count, nano_leaf_count,
    # Static arrays
    SMat3d,
    # Grid builder
    gaussian_splat,
    # Writer
    write_vdb_to_buffer,
    # Phase functions
    PhaseFunction, IsotropicPhase, HenyeyGreensteinPhase, sample_phase,
    # Output
    tonemap_reinhard, tonemap_aces, tonemap_exposure, auto_exposure,
    denoise_nlm, denoise_bilateral,
    # Field Protocol
    center, extent,
    # Volume internals
    delta_tracking_step, ratio_tracking,
    # GPU
    gpu_render_volume,
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
    include("test_parsing_infrastructure.jl")
    include("test_elegance_sprint.jl")
    include("test_accessors.jl")
    include("test_interpolation.jl")
    include("test_stencils.jl")
    include("test_differential_ops.jl")
    include("test_level_set_ops.jl")
    include("test_filtering.jl")
    include("test_morphology.jl")
    include("test_particles_to_sdf.jl")
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
    include("test_compression_write.jl")
    include("test_grid_builder.jl")
    include("test_pruning.jl")
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
