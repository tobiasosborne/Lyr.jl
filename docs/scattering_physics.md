# Scattering Physics: Ground Truth Reference

Every equation used in the scattering visualization series is listed here with a unique
`EQ:TAG` that **must** appear as a comment in the implementation source code. Each equation
cites the exact reference (author, title, edition, equation number, page).

## References

| Key | Full Citation | Local PDF |
|-----|--------------|-----------|
| **[Schwabl]** | F. Schwabl, *Quantum Mechanics*, 4th ed., Springer 2007, DOI 10.1007/978-3-540-71933-5 | `docs/references/schwabl_quantum_mechanics.pdf` |
| **[Greiner-RQM]** | W. Greiner, *Relativistic Quantum Mechanics: Wave Equations*, Springer 1990, DOI 10.1007/978-3-662-02634-2 | `docs/references/greiner_relativistic_qm.pdf` |
| **[Greiner-QED]** | W. Greiner & J. Reinhardt, *Quantum Electrodynamics*, 3rd ed., Springer 2003, DOI 10.1007/978-3-662-05246-4 | `docs/references/greiner_quantum_electrodynamics.pdf` |
| **[Greiner-QM]** | W. Greiner, *Quantum Mechanics: An Introduction*, 4th ed., Springer 2001, DOI 10.1007/978-3-642-56826-8 | `docs/references/greiner_quantum_mechanics.pdf` |
| **[Greiner-FQ]** | W. Greiner & J. Reinhardt, *Field Quantization*, Springer, DOI 10.1007/978-3-642-61485-9 | `docs/references/greiner_field_quantization.pdf` |
| **[KW1968]** | W. Kolos & L. Wolniewicz, "Improved Theoretical Ground-State Energy of the Hydrogen Molecule," *J. Chem. Phys.* **49**, 404–410 (1968), DOI 10.1063/1.1669836 | `docs/references/kolos_wolniewicz_1968.pdf` |

---

## Conventions

- **SI-adjacent atomic units** for non-relativistic QM: ℏ, m_e, e, a_0 explicit
- **Natural units** ℏ = c = 1 for relativistic / QED sections (stated per block)
- **Gaussian QED units** in Greiner-QED (factor 4π in propagators); Heaviside-Lorentz equivalents noted
- Level sets: negative = inside, positive = outside (Lyr convention)
- Protons treated as **classical point particles** on trajectories; only electron clouds are quantum

---

## I. NON-RELATIVISTIC HYDROGEN

### EQ:H-EIGENSTATE — Hydrogen Eigenstates

$$\psi_{nlm}(r, \vartheta, \varphi) = R_{nl}(r)\, Y_{lm}(\vartheta, \varphi)$$

**Ref**: [Schwabl] Eq. (6.36), p. 128

Quantum numbers: n = 1,2,3,...; l = 0,1,...,n−1; m = −l,...,+l.
Degeneracy of E_n: n² (without spin), 2n² (with spin).

### EQ:H-ENERGY — Energy Eigenvalues

$$E_n = -\frac{m_e Z^2 e_0^4}{2\hbar^2 n^2} = -\frac{(Ze_0)^2}{2 a_0 n^2} = -\frac{13.6\,\text{eV}}{n^2}\,(Z=1)$$

**Ref**: [Schwabl] Eq. (6.24′), p. 126; Eq. (6.41), p. 129

### EQ:BOHR-RADIUS — Bohr Radius

$$a_0 = \frac{\hbar^2}{m_e e_0^2} = 0.529 \times 10^{-8}\,\text{cm}$$

**Ref**: [Schwabl] Eq. (6.39), p. 128

### EQ:H-RADIAL — Radial Wavefunction

$$R_{nl}(r) = -\left[\frac{(n-l-1)!\,(2\kappa)^3}{2n\,((n+l)!)^3}\right]^{1/2} (2\kappa r)^l\, e^{-\kappa r}\, L_{n+l}^{2l+1}(2\kappa r)$$

with $\kappa = Z/(n a_0)$.

**Ref**: [Schwabl] Eq. (6.37), p. 128

### EQ:H-RADIAL-1S — Explicit 1s Orbital (n=1, l=0)

$$R_{10}(r) = 2\left(\frac{Z}{a_0}\right)^{3/2} e^{-Zr/a_0}$$

**Ref**: [Schwabl] Eq. (6.43), p. 129

### EQ:H-RADIAL-2S — Explicit 2s Orbital (n=2, l=0)

$$R_{20}(r) = 2\left(\frac{Z}{2a_0}\right)^{3/2}\left(1 - \frac{Zr}{2a_0}\right) e^{-Zr/2a_0}$$

**Ref**: [Schwabl] Eq. (6.43), p. 129

### EQ:H-RADIAL-2P — Explicit 2p Orbital (n=2, l=1)

$$R_{21}(r) = \frac{1}{\sqrt{3}}\left(\frac{Z}{2a_0}\right)^{3/2} \frac{Zr}{a_0}\, e^{-Zr/2a_0}$$

**Ref**: [Schwabl] Eq. (6.43), p. 130

### EQ:SPHERICAL-HARMONICS — Spherical Harmonics

$$Y_{lm}(\vartheta, \varphi) = (-1)^{(m+|m|)/2} \left[\frac{2l+1}{4\pi}\,\frac{(l-|m|)!}{(l+|m|)!}\right]^{1/2} P_{l|m|}(\cos\vartheta)\, e^{im\varphi}$$

**Ref**: [Schwabl] Eq. (5.22), p. 114

Low-order explicit values ([Schwabl] Eq. (5.34), p. 115):

| l,m | Y_lm |
|-----|------|
| 0,0 | 1/√(4π) |
| 1,0 | √(3/4π) cos θ |
| 1,±1 | ∓√(3/8π) sin θ e^(±iφ) |

### EQ:H-ORTHO — Orthonormality

$$\int d^3x\, \psi^*_{nlm}\, \psi_{n'l'm'} = \delta_{nn'}\,\delta_{ll'}\,\delta_{mm'}$$

**Ref**: [Schwabl] Eq. (6.42), p. 129

---

## II. GAUSSIAN WAVEPACKETS

### EQ:WAVEPACKET-3D — Free Particle Wave Packet (3D)

$$\psi(\boldsymbol{x}, t) = \int \frac{d^3p}{(2\pi\hbar)^3}\,\varphi(\boldsymbol{p})\,\exp\!\left\{\frac{i}{\hbar}\left(\boldsymbol{p}\cdot\boldsymbol{x} - \frac{p^2}{2m}t\right)\right\}$$

**Ref**: [Schwabl] Eq. (2.5), p. 16

### EQ:GAUSSIAN-PROFILE — Gaussian Momentum Profile (1D)

$$\varphi(p) = (8\pi d^2)^{1/4}\,\exp\!\left\{-(p - p_0)^2 d^2/\hbar^2\right\}$$

**Ref**: [Schwabl] Eqs. (2.6) and (2.13), pp. 16–17

Parameters: p_0 = central momentum, d = initial position width.

### EQ:WAVEPACKET-SPREADING — Probability Density (Spreading Gaussian)

$$|\psi(x,t)|^2 = \frac{1}{d\sqrt{2\pi(1+\Delta^2)}}\,\exp\!\left\{-\frac{(x - v_g t)^2}{2d^2(1+\Delta^2)}\right\}$$

with group velocity $v_g = p_0/m$ and spreading parameter $\Delta(t) = \hbar t/(2m d^2)$.

**Ref**: [Schwabl] Eqs. (2.12) and (2.14), pp. 17

### EQ:WAVEPACKET-WIDTH — Position Uncertainty (Time-Dependent)

$$\Delta x(t) = d\sqrt{1 + \Delta(t)^2} = d\sqrt{1 + \left(\frac{\hbar t}{2md^2}\right)^2}$$

**Ref**: [Schwabl] Eq. (2.16), p. 18

### EQ:WAVEPACKET-MOMENTUM — Momentum Uncertainty (Constant)

$$\Delta p = \frac{\hbar}{2d}$$

**Ref**: [Schwabl] Eq. (2.23), p. 20

### EQ:SPREADING-CONDITION — Negligible Spreading Condition

$$\frac{t\,(\Delta p)^2}{m\hbar} \ll 1$$

**Ref**: [Schwabl] Eq. (2.108), p. 43

---

## III. BORN-OPPENHEIMER AND H₂ POTENTIAL

### EQ:BO-SEPARATION — Born-Oppenheimer Ansatz

$$\Psi(\boldsymbol{x}, \boldsymbol{X}) = \psi(\boldsymbol{x}|\boldsymbol{X})\,\Phi(\boldsymbol{X})$$

where $\psi$ solves the electronic Schrödinger equation at fixed nuclear positions $\boldsymbol{X}$,
and $\Phi$ is the nuclear wavefunction.

**Ref**: [Schwabl] Eq. (15.9), p. 273

### EQ:BO-NUCLEAR — Nuclear Schrödinger Equation

$$(T_N + \varepsilon(\boldsymbol{X}))\,\Phi(\boldsymbol{X}) = E\,\Phi(\boldsymbol{X})$$

with $\varepsilon(\boldsymbol{X}) = V_{NN}(\boldsymbol{X}) + E^{\mathrm{el}}(\boldsymbol{X})$ the effective potential energy surface (PES).

**Ref**: [Schwabl] Eq. (15.11), p. 273

### EQ:H2-HAMILTONIAN — H₂ Two-Electron Hamiltonian

$$H = -\frac{\hbar^2}{2m}\nabla_1^2 - \frac{\hbar^2}{2m}\nabla_2^2 - \frac{e^2}{|\boldsymbol{x}_1 - \boldsymbol{X}_A|} - \frac{e^2}{|\boldsymbol{x}_1 - \boldsymbol{X}_B|} - \frac{e^2}{|\boldsymbol{x}_2 - \boldsymbol{X}_A|} - \frac{e^2}{|\boldsymbol{x}_2 - \boldsymbol{X}_B|} + \frac{e^2}{|\boldsymbol{x}_1 - \boldsymbol{x}_2|} + \frac{e^2}{R}$$

**Ref**: [Schwabl] Eq. (15.25), p. 278

### EQ:H2-HEITLER-LONDON — Heitler-London Singlet/Triplet

$$\psi_s(1,2) = \frac{1}{\sqrt{2(1+S^2)}}[\psi_A(\boldsymbol{x}_1)\psi_B(\boldsymbol{x}_2) + \psi_B(\boldsymbol{x}_1)\psi_A(\boldsymbol{x}_2)]\,\chi_{\mathrm{singlet}}$$

$$\psi_t(1,2) = \frac{1}{\sqrt{2(1-S^2)}}[\psi_A(\boldsymbol{x}_1)\psi_B(\boldsymbol{x}_2) - \psi_B(\boldsymbol{x}_1)\psi_A(\boldsymbol{x}_2)]\,\chi_{\mathrm{triplet}}$$

**Ref**: [Schwabl] Eqs. (15.27a,b), p. 279

### EQ:H2-BINDING — H₂ Binding Energies

$$\varepsilon_{s/t}(R) = 2E_1 + \frac{Q(R) \pm A(R)}{1 \pm S(R)^2}$$

where + is singlet (bonding), − is triplet (antibonding), Q is Coulomb energy, A is exchange energy.

**Ref**: [Schwabl] Eq. (15.35), p. 281

### EQ:MORSE-POTENTIAL — Morse Potential (Approximation to H₂ PES)

$$V(R) = D_e\left(1 - e^{-a(R-R_e)}\right)^2$$

Parameters for H₂: $D_e \approx 4.747\,\text{eV}$, $R_e = 0.741\,\text{Å} = 1.401\,\text{a.u.}$, $a \approx 1.028\,\text{a.u.}^{-1}$

**Ref**: Morse potential is standard; H₂ equilibrium values from [KW1968] Table I (R_e = 1.4011 a.u.),
dissociation energy D₀ = 36,117.4 cm⁻¹ from [KW1968] p. 409.

### EQ:KW-PES — Kolos-Wolniewicz H₂ Ground-State Potential Energy Curve

The potential-energy curve $E(R)$ for the electronic ground state (¹Σ_g⁺) of H₂,
computed with 100-term wavefunction in double precision.

Selected values from [KW1968] Table II (in atomic units, 1 a.u. = 219,474.62 cm⁻¹):

| R (a.u.) | E (a.u.) | D (cm⁻¹) |
|-----------|----------|-----------|
| 1.0 | −1.12453881 | 27,333.11 |
| 1.2 | −1.16493435 | 36,198.90 |
| 1.4 | −1.17447498 | 38,292.83 |
| 1.4011 | −1.17447498 | 38,292.83 |
| 1.5 | −1.17285408 | 37,937.08 |
| 1.8 | −1.15506752 | 34,033.38 |
| 2.0 | −1.13813155 | 30,316.37 |
| 2.4 | −1.10242011 | 22,478.61 |
| 3.0 | −1.05731738 | 12,579.71 |

Equilibrium: R_e = 1.4011 a.u. (by linear interpolation, [KW1968] p. 405).

**Ref**: [KW1968] Table II, pp. 405–406

---

## IV. POLARIZABILITY

### EQ:H-POLARIZABILITY — Static Polarizability of Hydrogen

$$\alpha_H = \frac{9}{2}\,a_0^3$$

From second-order perturbation theory (Stark effect):
$E^{(2)} = -\frac{9}{4}\,a_0^3\,\mathcal{E}^2 = -\frac{1}{2}\alpha_H\,\mathcal{E}^2$

**Ref**: [Schwabl] Eq. (14.31), p. 267

### EQ:POLARIZATION-DEFORMATION — Polarization Deformation of 1s State

$$\delta\psi \sim \alpha_H\,\mathcal{E}\,r\,\cos\theta\,\psi_{1s}$$

The first-order perturbation mixes 1s with 2p (and higher l=1 states).
The dominant correction is proportional to $r\cos\theta = r\,Y_{10}/\sqrt{3/(4\pi)}$.

**Ref**: [Schwabl] §14.3, Eq. (14.29), p. 267; perturbation H₁ = −eℰz from Eq. (14.27).

---

## V. SCATTERING CROSS SECTIONS (NON-RELATIVISTIC)

### EQ:BORN-APPROX — Born Approximation Scattering Amplitude

$$f(\vartheta) = -\frac{m}{2\pi\hbar^2}\int d^3x'\,e^{i(\boldsymbol{k}-\boldsymbol{k}')\cdot\boldsymbol{x}'}\,V(\boldsymbol{x}') = -\frac{m}{2\pi\hbar^2}\,\tilde{V}(\boldsymbol{q})$$

where $\boldsymbol{q} = \boldsymbol{k}' - \boldsymbol{k}$ is the momentum transfer.

**Ref**: [Schwabl] Eq. (18.48), p. 337

### EQ:RUTHERFORD — Rutherford Cross Section

$$\frac{d\sigma}{d\Omega} = \left(\frac{Z_1 Z_2 e^2}{4 E_k}\right)^2 \frac{1}{\sin^4(\vartheta/2)}$$

**Ref**: [Schwabl] Eq. (18.51b), p. 338.
Note: this is exact for the Coulomb potential — the Born approximation accidentally gives the exact result.

---

## VI. DIRAC EQUATION (RELATIVISTIC)

Convention: natural units ℏ = c = 1 unless otherwise noted.

### EQ:DIRAC-FREE — Free Dirac Equation (Covariant Form)

$$(i\gamma^\mu \partial_\mu - m)\,\psi = 0$$

or equivalently $(\not{p} - m)\psi = 0$ with $\not{p} = \gamma^\mu p_\mu$.

Gamma matrices satisfy the Clifford algebra: $\{\gamma^\mu, \gamma^\nu\} = 2g^{\mu\nu}$.

**Ref**: [Greiner-RQM] Eqs. (3.16)–(3.17), p. 101–102; Eq. (3.11), p. 101

Standard (Dirac) representation ([Greiner-RQM] Eq. (3.13), p. 101):

$$\gamma^0 = \begin{pmatrix} \mathbb{1} & 0 \\ 0 & -\mathbb{1} \end{pmatrix}, \quad \gamma^i = \begin{pmatrix} 0 & \sigma^i \\ -\sigma^i & 0 \end{pmatrix}$$

### EQ:DIRAC-SPINOR-POS — Positive-Energy Dirac Spinor u(p,s)

$$(\not{p} - m)\,u(p,s) = 0$$

Explicit form for arbitrary 3-momentum $\boldsymbol{p} = (p_x, p_y, p_z)$, with $p_\pm = p_x \pm ip_y$:

$$u^{(1)}(\boldsymbol{p}) = \sqrt{\frac{E+m}{2m}} \begin{pmatrix}1\\0\\p_z/(E+m)\\p_+/(E+m)\end{pmatrix}, \quad u^{(2)}(\boldsymbol{p}) = \sqrt{\frac{E+m}{2m}} \begin{pmatrix}0\\1\\p_-/(E+m)\\-p_z/(E+m)\end{pmatrix}$$

Normalization: $\bar{u}\,u = +1$.

**Ref**: [Greiner-RQM] Eq. (6.30), p. 130; Eq. (6.47), p. 141; Eq. (6.34), p. 134

### EQ:DIRAC-SPINOR-NEG — Negative-Energy Dirac Spinor v(p,s)

$$(\not{p} + m)\,v(p,s) = 0$$

$$v^{(1)}(\boldsymbol{p}) = \sqrt{\frac{E+m}{2m}} \begin{pmatrix}p_z/(E+m)\\p_+/(E+m)\\1\\0\end{pmatrix}, \quad v^{(2)}(\boldsymbol{p}) = \sqrt{\frac{E+m}{2m}} \begin{pmatrix}p_-/(E+m)\\-p_z/(E+m)\\0\\1\end{pmatrix}$$

Normalization: $\bar{v}\,v = -1$.

**Ref**: [Greiner-RQM] Eq. (6.55), p. 142; Eq. (6.30), p. 130

### EQ:DIRAC-WAVEPACKET — Dirac Wavepacket

$$\psi^{(+)}(\boldsymbol{x},t) = \int \frac{d^3p}{(2\pi)^{3/2}}\,\sqrt{\frac{m}{E_p}}\sum_{s} b(p,s)\,u(p,s)\,e^{-ip\cdot x}$$

**Ref**: [Greiner-RQM] Eq. (8.1), p. 151

### EQ:DIRAC-CURRENT — Conserved Four-Current

$$j^\mu = \bar{\psi}\,\gamma^\mu\,\psi, \qquad \partial_\mu j^\mu = 0$$

Probability density: $\rho = j^0 = \psi^\dagger\psi \geq 0$.

**Ref**: [Greiner-RQM] Eqs. (3.64)–(3.67), pp. 116–117

### EQ:ADJOINT-SPINOR — Adjoint Spinor

$$\bar{\psi} \equiv \psi^\dagger \gamma^0$$

**Ref**: [Greiner-RQM] Eq. (3.67), p. 117

---

## VII. QED TREE-LEVEL

Convention: Gaussian units with ℏ = c = 1; photon propagator carries 4π.
Heaviside-Lorentz equivalents given in parentheses (drop 4π from propagator).

### EQ:QED-VERTEX — QED Interaction Vertex

Each electron-photon vertex contributes:

$$-ie\gamma^\mu$$

Fine structure constant: $\alpha = e^2 \approx 1/137$ (Gaussian); $\alpha = e^2/(4\pi)$ (HL).

**Ref**: [Greiner-QED] Rule 4, p. 261; Eq. (4.15)

### EQ:PHOTON-PROPAGATOR — Feynman Photon Propagator (Momentum Space)

$$iD_F^{\mu\nu}(k) = \frac{-i\,4\pi\,g^{\mu\nu}}{k^2 + i\epsilon} \qquad\text{(Gaussian)}$$

$$iD_F^{\mu\nu}(k) = \frac{-i\,g^{\mu\nu}}{k^2 + i\epsilon} \qquad\text{(Heaviside-Lorentz)}$$

in Feynman gauge.

**Ref**: [Greiner-QED] Eqs. (3.47) and (4.5), pp. 107, 261

### EQ:ELECTRON-PROPAGATOR — Feynman Electron Propagator

$$iS_F(p) = \frac{i(\not{p} + m)}{p^2 - m^2 + i\epsilon}$$

**Ref**: [Greiner-QED] Eq. (2.19), p. 52; Rule 3a, p. 261

### EQ:ELECTRON-CURRENT — QED Electron Transition Current

$$j^\mu_{fi}(x) = e\,\bar{\psi}_f(x)\,\gamma^\mu\,\psi_i(x)$$

**Ref**: [Greiner-QED] Eq. (4.3) context, p. 259

### EQ:MOLLER-AMP — Møller Scattering Amplitude (e⁻e⁻ → e⁻e⁻)

$$i\mathcal{M} = (ie)^2 \left[\frac{\bar{u}(p_3)\gamma^\mu u(p_1)\;\bar{u}(p_4)\gamma_\mu u(p_2)}{(p_1-p_3)^2} - \frac{\bar{u}(p_4)\gamma^\mu u(p_1)\;\bar{u}(p_3)\gamma_\mu u(p_2)}{(p_1-p_4)^2}\right] \times 4\pi$$

First term: direct (t-channel, $q = p_1 - p_3$).
Second term: exchange (u-channel, $q = p_1 - p_4$), with relative minus sign from Fermi statistics.

In Heaviside-Lorentz units, drop the 4π factor.

**Ref**: [Greiner-QED] Eq. (3.115), pp. 141–142

### EQ:MOLLER-XSEC-UR — Møller Cross Section (Ultrarelativistic, CM Frame)

$$\left(\frac{d\bar{\sigma}}{d\Omega}\right)_{\text{UR}} = \frac{\alpha^2}{8E^2}\left[\frac{1+\cos^4(\theta/2)}{\sin^4(\theta/2)} + \frac{1+\sin^4(\theta/2)}{\cos^4(\theta/2)} + \frac{2}{\sin^2(\theta/2)\cos^2(\theta/2)}\right]$$

Simplified: $= \alpha^2(3+\cos^2\theta)^2/(4E^2\sin^4\theta)$

**Ref**: [Greiner-QED] Eq. (3.139), pp. 147–148

### EQ:VIRTUAL-PHOTON — Virtual Photon Field (Position Space Convolution)

$$A^\mu(x) = \int d^4x'\, D_F^{\mu\nu}(x - x')\, j_\nu(x')$$

This is the standard convolution of the Feynman propagator with the electron current.
For visualization: evaluate on a 3D spatial grid at fixed time.

**Ref**: Standard QED; propagator from [Greiner-QED] Eq. (3.44), p. 105.

---

## VIII. SPIN SUMS AND TRACE TECHNOLOGY

### EQ:SPIN-SUM-U — Positive-Energy Spin Sum

$$\sum_{s=1,2} u_\alpha(p,s)\,\bar{u}_\beta(p,s) = \left(\frac{\not{p}+m}{2m}\right)_{\alpha\beta}$$

### EQ:SPIN-SUM-V — Negative-Energy Spin Sum

$$\sum_{s=1,2} v_\alpha(p,s)\,\bar{v}_\beta(p,s) = \left(\frac{\not{p}-m}{2m}\right)_{\alpha\beta}$$

**Ref**: [Greiner-RQM] Eq. (6.34), p. 134; [Greiner-QED] context of Eq. (3.121), p. 143

---

## IX. IMPLEMENTATION NOTES

### Classical Proton Approximation

For the H-H scattering scenarios (1–4), proton positions $\boldsymbol{R}_A(t)$, $\boldsymbol{R}_B(t)$ evolve on
classical trajectories governed by:

$$M\ddot{\boldsymbol{R}} = -\nabla_{\boldsymbol{R}}\,\varepsilon(R)$$

where $\varepsilon(R)$ is the Born-Oppenheimer PES (EQ:BO-NUCLEAR). For the Morse
approximation use EQ:MORSE-POTENTIAL. For high-accuracy use the tabulated
Kolos-Wolniewicz curve (EQ:KW-PES).

### Orbital Truncation Justification

For elastic H-H scattering at low energy, the electron clouds remain near the
ground state. We truncate to the first few orbitals:

- **1s** (EQ:H-RADIAL-1S): dominant at all R
- **2s** (EQ:H-RADIAL-2S): mixed in at close approach via polarization (EQ:H-POLARIZABILITY)
- **2p** (EQ:H-RADIAL-2P): Stark mixing ∝ ℰ·r·cos θ (EQ:POLARIZATION-DEFORMATION)

This is justified because:
1. The polarizability α_H = 9a₀³/2 gives the leading deformation ([Schwabl] §14.3)
2. Higher orbitals (n≥3) contribute < 5% to the polarizability sum ([Schwabl] Eq. 14.29)
3. For inelastic scattering (scenarios 3–4), we include n=3 shells explicitly

### Visualization Pipeline

Each equation produces a scalar or vector field evaluated on a 3D grid:

1. **Hydrogen density**: |ψ_{nlm}|² → `ScalarField3D` → `voxelize` → `VolumeEntry`
2. **Wavepacket density**: |ψ(x,t)|² from FFT of Gaussian profile → time series of grids
3. **Dirac density**: ψ†ψ → positive-definite density for relativistic electrons
4. **Virtual photon**: |A^μ(x)| from convolution EQ:VIRTUAL-PHOTON → glow field between electrons

All fields feed into Lyr's Field Protocol (`ScalarField3D` → `voxelize` → `visualize`).
