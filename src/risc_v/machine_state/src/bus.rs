// SPDX-FileCopyrightText: 2023 TriliTech <contact@trili.tech>
//
// SPDX-License-Identifier: MIT

pub mod devices;
pub mod main_memory;

use crate::{backend, registers};

/// Bus address
pub type Address = registers::XValue;

/// An address is out of bounds.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub struct OutOfBounds;

/// Addressable space
pub trait Addressable<E: backend::Elem> {
    /// Read an element of type `E` from the given address.
    fn read(&self, addr: Address) -> Result<E, OutOfBounds>;

    /// Write an element of type `E` to the given address.
    fn write(&mut self, addr: Address, value: E) -> Result<(), OutOfBounds>;
}

/// Address space identifier
enum AddressSpace {
    Devices,
    MainMemory,
    OutOfBounds,
}

impl AddressSpace {
    /// Determine which address space the address belongs to.
    #[inline(always)]
    fn locate<ML: main_memory::MainMemoryLayout>(addr: Address) -> (Self, Address) {
        // Is the address within the devices address space?
        if addr < devices::DEVICES_ADDRESS_SPACE_LENGTH {
            return (AddressSpace::Devices, addr);
        }

        let mem_addr = addr.saturating_sub(devices::DEVICES_ADDRESS_SPACE_LENGTH);
        let mem_size: u64 = ML::LEN8.try_into().expect("ML::LEN8 out of bounds");

        // Is the address within the main memory address space?
        if mem_addr < mem_size {
            return (AddressSpace::MainMemory, mem_addr);
        }

        // Address is entirely out of bounds.
        (AddressSpace::OutOfBounds, addr)
    }
}

/// Layout of the Bus
pub type BusLayout<ML> = (devices::DevicesLayout, ML);

/// Bus connects to the main memory and other devices.
pub struct Bus<ML: main_memory::MainMemoryLayout, M: backend::Manager> {
    devices: devices::Devices<M>,
    memory: main_memory::MainMemory<ML, M>,
}

impl<ML: main_memory::MainMemoryLayout, M: backend::Manager> Bus<ML, M> {
    /// Bind the Bus state to the allocated space.
    pub fn new_in(space: backend::AllocatedOf<BusLayout<ML>, M>) -> Self {
        Self {
            devices: devices::Devices::new_in(space.0),
            memory: main_memory::MainMemory::new_in(space.1),
        }
    }
}

impl<E, ML, M> Addressable<E> for Bus<ML, M>
where
    E: backend::Elem,
    ML: main_memory::MainMemoryLayout,
    M: backend::Manager,
    devices::Devices<M>: Addressable<E>,
    main_memory::MainMemory<ML, M>: Addressable<E>,
{
    #[inline(always)]
    fn read(&self, addr: Address) -> Result<E, OutOfBounds> {
        let (addr_space, local_address) = AddressSpace::locate::<ML>(addr);
        match addr_space {
            AddressSpace::Devices => self.devices.read(local_address),
            AddressSpace::MainMemory => self.memory.read(local_address),
            AddressSpace::OutOfBounds => Err(OutOfBounds),
        }
    }

    #[inline(always)]
    fn write(&mut self, addr: Address, value: E) -> Result<(), OutOfBounds> {
        let (addr_space, local_address) = AddressSpace::locate::<ML>(addr);
        match addr_space {
            AddressSpace::Devices => self.devices.write(local_address, value),
            AddressSpace::MainMemory => self.memory.write(local_address, value),
            AddressSpace::OutOfBounds => Err(OutOfBounds),
        }
    }
}
