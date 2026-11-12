//! GPU batch simulation — wgpu compute backend (feature `gpu`).
//!
//! One WGSL kernel invocation per lane per tick. State lives in a storage
//! buffer; inputs (thrust/torque) come from a separate read-only buffer.
//! The cave is evaluated analytically in the shader (sin + fract) — no
//! polygons, no knots to upload.
//!
//! NOTE on determinism: sin() ULP behavior differs between CPU (libm) and GPU
//! (driver). Results are *visually* and *physically* identical corridors but
//! may differ by ~1e-6 at a single wall-contact tick. Acceptable for mass-
//! ively parallel reinforcement learning rollouts.

#[cfg(feature = "gpu")]
mod imp {
    use wgpu::util::DeviceExt;

    #[repr(C)]
    #[derive(Copy, Clone, Debug, bytemuck::Pod, bytemuck::Zeroable)]
    pub struct GpuLane {
        pub pos_x: f32,
        pub pos_y: f32,
        pub vel_x: f32,
        pub vel_y: f32,
        pub angle: f32,
        pub alive: f32,       // 1.0 alive, 0.0 dead
        pub max_depth: f32,
        pub cur_depth: f32,
        pub tick: u32,
        pub spawn_tick: u32,
        pub _pad0: u32,
        pub _pad1: u32,
        pub time_alive: f32,
        pub time_scale: f32,
        pub session_best: f32,
        pub session_sum_score: f32,
        pub session_sum_time: f32,
        pub session_runs: f32,
        pub session_best_time: f32,
        pub _pad2: f32,
    }

    impl Default for GpuLane {
        fn default() -> Self {
            Self {
                pos_x: 0.0,
                pos_y: 0.0,
                vel_x: 0.0,
                vel_y: 0.0,
                angle: 0.0,
                alive: 1.0,
                max_depth: 0.0,
                cur_depth: 0.0,
                tick: 0,
                spawn_tick: 0,
                _pad0: 0,
                _pad1: 0,
                time_alive: 0.0,
                time_scale: 1.0,
                session_best: 0.0,
                session_sum_score: 0.0,
                session_sum_time: 0.0,
                session_runs: 0.0,
                session_best_time: 0.0,
                _pad2: 0.0,
            }
        }
    }

    #[repr(C)]
    #[derive(Copy, Clone, Debug, bytemuck::Pod, bytemuck::Zeroable)]
    pub struct GpuInput {
        pub thrust: f32,   // 0.0 / 1.0
        pub torque: f32,   // -1..1
    }

    pub struct GpuBatch {
        pub device: wgpu::Device,
        pub queue: wgpu::Queue,
        pub pipeline: wgpu::ComputePipeline,
        pub bind_group: wgpu::BindGroup,
        pub lanes_buf: wgpu::Buffer,
        pub input_buf: wgpu::Buffer,
        pub readback_buf: wgpu::Buffer,
        pub n_lanes: u32,
    }

    impl GpuBatch {
        pub fn new(n_lanes: u32, time_scale: f32) -> Result<Self, String> {
            let instance = wgpu::Instance::default();
            let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::HighPerformance,
                ..Default::default()
            }))
            .ok_or_else(|| "no GPU adapter found".to_string())?;

            let (device, queue) = pollster::block_on(adapter.request_device(
                &wgpu::DeviceDescriptor {
                    label: Some("rocket-landing-env-gpu"),
                    required_features: wgpu::Features::empty(),
                    required_limits: wgpu::Limits::downlevel_defaults(),
                },
                None,
            ))
            .map_err(|e| format!("device request failed: {e}"))?;

            let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
                label: Some("batch.wgsl"),
                source: wgpu::ShaderSource::Wgsl(include_str!("../shaders/batch.wgsl").into()),
            });

            let lanes: Vec<GpuLane> = (0..n_lanes)
                .map(|_| GpuLane { time_scale, ..Default::default() })
                .collect();
            let inputs = vec![GpuInput { thrust: 0.0, torque: 0.0 }; n_lanes as usize];

            let lanes_buf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("lanes"),
                contents: bytemuck::cast_slice(&lanes),
                usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC | wgpu::BufferUsages::COPY_DST,
            });
            let input_buf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("inputs"),
                contents: bytemuck::cast_slice(&inputs),
                usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST,
            });
            let readback_buf = device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("readback"),
                size: (std::mem::size_of::<GpuLane>() * n_lanes as usize) as u64,
                usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
                mapped_at_creation: false,
            });

            let bind_group_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
                label: Some("batch_bgl"),
                entries: &[
                    wgpu::BindGroupLayoutEntry {
                        binding: 0,
                        visibility: wgpu::ShaderStages::COMPUTE,
                        ty: wgpu::BindingType::Buffer {
                            ty: wgpu::BufferBindingType::Storage { read_only: false },
                            has_dynamic_offset: false,
                            min_binding_size: None,
                        },
                        count: None,
                    },
                    wgpu::BindGroupLayoutEntry {
                        binding: 1,
                        visibility: wgpu::ShaderStages::COMPUTE,
                        ty: wgpu::BindingType::Buffer {
                            ty: wgpu::BufferBindingType::Storage { read_only: true },
                            has_dynamic_offset: false,
                            min_binding_size: None,
                        },
                        count: None,
                    },
                ],
            });

            let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("batch_pl"),
                bind_group_layouts: &[&bind_group_layout],
                push_constant_ranges: &[],
            });

            let pipeline = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
                label: Some("batch_pipeline"),
                layout: Some(&pipeline_layout),
                module: &shader,
                entry_point: "step_lanes",
                compilation_options: wgpu::PipelineCompilationOptions::default(),
            });

            let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("batch_bg"),
                layout: &bind_group_layout,
                entries: &[
                    wgpu::BindGroupEntry { binding: 0, resource: lanes_buf.as_entire_binding() },
                    wgpu::BindGroupEntry { binding: 1, resource: input_buf.as_entire_binding() },
                ],
            });

            Ok(GpuBatch { device, queue, pipeline, bind_group, lanes_buf, input_buf, readback_buf, n_lanes })
        }

        pub fn step(&self) {
            let mut enc = self.device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("step") });
            {
                let mut cpass = enc.begin_compute_pass(&wgpu::ComputePassDescriptor { label: Some("step"), timestamp_writes: None });
                cpass.set_pipeline(&self.pipeline);
                cpass.set_bind_group(0, &self.bind_group, &[]);
                cpass.dispatch_workgroups((self.n_lanes + 63) / 64, 1, 1);
            }
            enc.copy_buffer_to_buffer(&self.lanes_buf, 0, &self.readback_buf, 0, (std::mem::size_of::<GpuLane>() * self.n_lanes as usize) as u64);
            self.queue.submit(Some(enc.finish()));
        }

        /// Map + read lanes; caller must `unmap()` afterwards.
        pub fn read_lanes(&self) -> Vec<GpuLane> {
            let slice = self.readback_buf.slice(..);
            let (tx, rx) = futures::channel::oneshot::channel();
            slice.map_async(wgpu::MapMode::Read, move |res| {
                let _ = tx.send(res);
            });
            self.device.poll(wgpu::Maintain::Wait);
            let _ = futures::executor::block_on(rx);
            let data = slice.get_mapped_range();
            bytemuck::cast_slice(&data).to_vec()
        }

        pub fn unmap(&self) {
            self.readback_buf.unmap();
        }

        pub fn set_inputs(&self, inputs: &[GpuInput]) {
            self.queue.write_buffer(&self.input_buf, 0, bytemuck::cast_slice(inputs));
        }

        pub fn reset_lanes(&self, time_scale: f32) {
            let lanes: Vec<GpuLane> = (0..self.n_lanes)
                .map(|_| GpuLane { time_scale, ..Default::default() })
                .collect();
            self.queue.write_buffer(&self.lanes_buf, 0, bytemuck::cast_slice(&lanes));
        }
    }

    /// Constructor used by the Python bindings.
    pub fn init(n_lanes: u32, time_scale: f32) -> Result<GpuBatch, String> {
        GpuBatch::new(n_lanes, time_scale)
    }
}

#[cfg(feature = "gpu")]
pub use imp::*;

#[cfg(not(feature = "gpu"))]
mod stub {
    //! GPU backend unavailable in this build.
    pub struct GpuBatch;
    /// Always fails with a helpful message.
    pub fn init(_n_lanes: u32, _time_scale: f32) -> Result<GpuBatch, String> {
        Err("GPU backend disabled: rebuild with `--features gpu`".to_string())
    }
}

#[cfg(not(feature = "gpu"))]
pub use stub::*;
