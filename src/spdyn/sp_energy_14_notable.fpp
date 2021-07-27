!--------1---------2---------3---------4---------5---------6---------7---------8
!
!  Module   sp_energy_14_notable_mod
!> @brief   calculate nonbonded energy without table for vdw
!! @authors Jaewoon Jung(JJ)
!  
!  (c) Copyright 2014 RIKEN. All rights reserved.
!
!--------1---------2---------3---------4---------5---------6---------7---------8

#ifdef HAVE_CONFIG_H
#include "../config.h"
#endif

module sp_energy_14_notable_mod

  use sp_pairlist_str_mod
  use sp_enefunc_str_mod
  use sp_domain_str_mod
  use mpi_parallel_mod
  use constants_mod
  use timers_mod

  implicit none
  private

  ! subroutines
  !
  public  :: compute_energy_nonbond14_notable
  private :: compute_energy_nonbond14_notable_gro_amber_intel
  private :: compute_energy_nonbond14_notable_gro_amber_fugaku
  private :: compute_energy_nonbond14_notable_gro_amber_generic
  private :: compute_energy_nonbond14_notable_gro_amber_check

contains
  !======1=========2=========3=========4=========5=========6=========7=========8
  !
  !  Subroutine    compute_energy_nonbond14_table
  !> @brief        calculate nonbonded14 energy without lookup table of vdw
  !  @authors      JJ
  !! @param[in]    domain  : domain information
  !! @param[in]    enefunc : potential energy functions
  !! @param[inout] force   : forces for each cell
  !! @param[inout] eelec   : electrostatic energy of target systems
  !! @param[inout] evdw    : van der Waals energy of target systems
  !
  !======1=========2=========3=========4=========5=========6=========7=========8

  subroutine compute_energy_nonbond14_notable(domain, enefunc, atmcls, coord, &
                                        force, force_pbc, virial, eelec, evdw)

    ! formal arguments
    type(s_domain),  target, intent(in)    :: domain
    type(s_enefunc), target, intent(in)    :: enefunc
    integer,                 intent(in)    :: atmcls(:)
    real(wp),                intent(in)    :: coord(:,:,:)
    real(wp),                intent(inout) :: force(:,:,:,:)
    real(wp),                intent(inout) :: force_pbc(:,:,:,:)
    real(dp),                intent(inout) :: virial(:,:,:)
    real(dp),                intent(inout) :: eelec(nthread)
    real(dp),                intent(inout) :: evdw(nthread)

    if (enefunc%nonb_limiter) then

      call compute_energy_nonbond14_notable_gro_amber_check( &
                              domain, enefunc, coord, force, virial, &
                              eelec, evdw)

    else

      if (domain%nonbond_kernel == NBK_Intel) then
        call compute_energy_nonbond14_notable_gro_amber_intel( &
                              domain, enefunc, atmcls, coord,        &
                              force_pbc, virial, eelec, evdw)
      else if (domain%nonbond_kernel == NBK_Fugaku) then
        call compute_energy_nonbond14_notable_gro_amber_fugaku( &
                              domain, enefunc, atmcls, coord,        &
                              force_pbc, virial, eelec, evdw)
      else if (domain%nonbond_kernel == NBK_GPU) then
        call compute_energy_nonbond14_notable_gro_amber_gpu( &
                              domain, enefunc, atmcls, coord,        &
                              force, virial, eelec, evdw)
      else
        call compute_energy_nonbond14_notable_gro_amber_generic( &
                              domain, enefunc, coord, force, virial, &
                              eelec, evdw)
      end if

    endif
    
    return

  end subroutine compute_energy_nonbond14_notable

  !======1=========2=========3=========4=========5=========6=========7=========8
  !
  !  Subroutine    compute_energy_nonbond14_notable_gro_amber_intel
  !> @brief        calculate nonbonded14 energy with PME and lookup table
  !!               (linear, intel kernel)
  !  @authors      JJ
  !! @param[in]    domain  : domain information
  !! @param[in]    enefunc : potential energy functions
  !! @param[inout] force   : forces for each cell
  !! @param[inout] eelec   : electrostatic energy of target systems
  !! @param[inout] evdw    : van der Waals energy of target systems
  !
  !======1=========2=========3=========4=========5=========6=========7=========8

  subroutine compute_energy_nonbond14_notable_gro_amber_intel(domain, enefunc, &
                                    atmcls, coord, force, virial, eelec, evdw)

    ! formal arguments
    type(s_domain),  target, intent(in)    :: domain
    type(s_enefunc), target, intent(in)    :: enefunc
    integer,                 intent(in)    :: atmcls(:)
    real(wp),                intent(in)    :: coord(:,:,:)
    real(wp),                intent(inout) :: force(:,:,:,:)
    real(dp),                intent(inout) :: virial(:,:,:)
    real(dp),                intent(inout) :: eelec(nthread)
    real(dp),                intent(inout) :: evdw(nthread)

    ! local variables
    real(wp)                 :: dij(3), rij2
    real(wp)                 :: R, table(6)
    real(wp)                 :: term_lj12, term_lj6, term_elec
    real(wp)                 :: cutoff2, grad_coef, lj12, lj6
    real(wp)                 :: work(3), viri(3)
    real(wp)                 :: lj_scale, qq_scale, cc, iqtmp, jqtmp
    real(wp)                 :: inv_r12, inv_r121, inv_r123, inv_r126, inv_r1212
    real(wp)                 :: elec_temp, evdw_temp
    integer                  :: i, ix, iy, j, k, ij, m, L
    integer                  :: iatmcls, jatmcls
    integer                  :: num_nb14, ini_nb14, fin_nb14
    integer                  :: ncell_local, id, omp_get_thread_num

    real(wp),        pointer :: nb14_lj12(:,:), nb14_lj6(:,:)
    real(wp),        pointer :: table_ene(:), table_grad(:)
    real(wp),        pointer :: density, cutoff
    integer,         pointer ::  natom(:)
    integer(int2),   pointer :: cell_pair(:,:)
    integer,         pointer :: num_nb14_calc(:), nb14_calc_list(:,:,:)

    cell_pair       => domain%cell_pairlist1
    natom           => domain%num_atom

    table_ene       => enefunc%table%table_ene
    table_grad      => enefunc%table%table_grad
    density         => enefunc%table%density
    cutoff          => enefunc%cutoffdist
    nb14_lj12       => enefunc%nb14_lj12
    nb14_lj6        => enefunc%nb14_lj6
    num_nb14_calc   => enefunc%num_nb14_calc
    nb14_calc_list  => enefunc%nb14_calc_list

    cutoff2         =  cutoff * cutoff
    ncell_local     =  domain%num_cell_local


    !$omp parallel default(shared)                                             &
    !$omp private(id, i, j, k, ij, ix, iy, m, ini_nb14, fin_nb14, num_nb14,    &
    !$omp         dij, rij2, L, R, term_lj12, term_lj6, term_elec, grad_coef,  &
    !$omp         work, table, lj12, lj6, qq_scale, lj_scale, cc, inv_r12,     &
    !$omp         inv_r121, inv_r123, inv_r126, inv_r1212, iatmcls, jatmcls,   &
    !$omp         iqtmp, jqtmp, viri, evdw_temp, elec_temp)
    !
#ifdef OMP
    id = omp_get_thread_num()
#else
    id = 0
#endif

    ! calculate energy and gradient
    !
    do ij = id+1, ncell_local, nthread

      evdw_temp = 0.0_wp
      elec_temp = 0.0_wp
      viri(1:3) = 0.0_wp

      do k = 1, num_nb14_calc(ij)

        i  = nb14_calc_list(1,k,ij)
        j  = nb14_calc_list(2,k,ij)

        iatmcls = atmcls(i)
        jatmcls = atmcls(j)

        ! compute distance
        !
        dij(1) = coord(i,1,1) - coord(j,1,1)
        dij(2) = coord(i,2,1) - coord(j,2,1)
        dij(3) = coord(i,3,1) - coord(j,3,1)
        rij2     = dij(1)*dij(1) + dij(2)*dij(2) + dij(3)*dij(3)

        iqtmp  = coord(i,4,1)
        jqtmp  = coord(j,4,1)
        qq_scale = enefunc%nb14_qq_scale(k,ij)
        lj_scale = enefunc%nb14_lj_scale(k,ij)
        inv_r12  = 1.0_wp / rij2
        inv_r121 = sqrt(inv_r12)
        inv_r123 = inv_r12 * inv_r121
        inv_r126 = inv_r123 * inv_r123
        inv_r1212 = inv_r126 * inv_r126

        ! energy and gradient
        !
        rij2  = cutoff2*density/rij2
        L     = int(rij2)
        R     = rij2 - L
        lj6   = nb14_lj6 (iatmcls,jatmcls)
        lj12  = nb14_lj12(iatmcls,jatmcls)
        cc    = iqtmp * jqtmp * qq_scale

        term_lj12   = inv_r1212
        term_lj6    = inv_r126
        term_elec   = table_ene(L) + R*(table_ene(L+1)-table_ene(L))
        evdw_temp   = evdw_temp  + (term_lj12*lj12 - term_lj6*lj6)*lj_scale
        elec_temp   = elec_temp  + cc*term_elec

        term_lj12   = -12.0_wp * inv_r1212 * inv_r12
        term_lj6    = -6.0_wp * inv_r126 * inv_r12
        term_elec   = table_grad(L) + R*(table_grad(L+1)-table_grad(L))
        grad_coef   = (term_lj12*lj12 - term_lj6*lj6)*lj_scale + cc*term_elec

        work(1) = grad_coef*dij(1)
        work(2) = grad_coef*dij(2)
        work(3) = grad_coef*dij(3)
        viri(1) = viri(1) + dij(1)*work(1)
        viri(2) = viri(2) + dij(2)*work(2)
        viri(3) = viri(3) + dij(3)*work(3)

        force(i,1,1,id+1) = force(i,1,1,id+1) - work(1)
        force(i,2,1,id+1) = force(i,2,1,id+1) - work(2)
        force(i,3,1,id+1) = force(i,3,1,id+1) - work(3)
        force(j,1,1,id+1) = force(j,1,1,id+1) + work(1)
        force(j,2,1,id+1) = force(j,2,1,id+1) + work(2)
        force(j,3,1,id+1) = force(j,3,1,id+1) + work(3)

      end do

      virial(1,1,id+1) = virial(1,1,id+1) - viri(1)
      virial(2,2,id+1) = virial(2,2,id+1) - viri(2)
      virial(3,3,id+1) = virial(3,3,id+1) - viri(3)
      evdw(id+1)  = evdw(id+1) + evdw_temp
      eelec(id+1) = eelec(id+1) + elec_temp

    end do

    !$omp end parallel

    return

  end subroutine compute_energy_nonbond14_notable_gro_amber_intel

  !======1=========2=========3=========4=========5=========6=========7=========8
  !
  !  Subroutine    compute_energy_nonbond14_notable_gro_amber_fugaku
  !> @brief        calculate nonbonded14 energy with PME and lookup table
  !!               (linear, fugaku kernel)
  !  @authors      JJ
  !! @param[in]    domain  : domain information
  !! @param[in]    enefunc : potential energy functions
  !! @param[inout] force   : forces for each cell
  !! @param[inout] eelec   : electrostatic energy of target systems
  !! @param[inout] evdw    : van der Waals energy of target systems
  !
  !======1=========2=========3=========4=========5=========6=========7=========8

  subroutine compute_energy_nonbond14_notable_gro_amber_fugaku(domain, enefunc,&
                                    atmcls, coord, force, virial, eelec, evdw)

    ! formal arguments
    type(s_domain),  target, intent(in)    :: domain
    type(s_enefunc), target, intent(in)    :: enefunc
    integer,                 intent(in)    :: atmcls(:)
    real(wp),                intent(in)    :: coord(:,:,:)
    real(wp),                intent(inout) :: force(:,:,:,:)
    real(dp),                intent(inout) :: virial(:,:,:)
    real(dp),                intent(inout) :: eelec(nthread)
    real(dp),                intent(inout) :: evdw(nthread)

    ! local variables
    real(wp)                 :: dij(3), rij2
    real(wp)                 :: R, table(6)
    real(wp)                 :: term_lj12, term_lj6, term_elec
    real(wp)                 :: cutoff2, grad_coef, lj12, lj6
    real(wp)                 :: work(3), viri(3)
    real(wp)                 :: lj_scale, qq_scale, cc, iqtmp, jqtmp
    real(wp)                 :: inv_r12, inv_r121, inv_r123, inv_r126, inv_r1212
    real(wp)                 :: elec_temp, evdw_temp
    integer                  :: i, ix, iy, j, k, ij, m, L
    integer                  :: iatmcls, jatmcls
    integer                  :: num_nb14, ini_nb14, fin_nb14
    integer                  :: ncell_local, id, omp_get_thread_num

    real(wp),        pointer :: nb14_lj12(:,:), nb14_lj6(:,:)
    real(wp),        pointer :: table_ene(:), table_grad(:)
    real(wp),        pointer :: density, cutoff
    integer,         pointer ::  natom(:)
    integer(int2),   pointer :: cell_pair(:,:)
    integer,         pointer :: num_nb14_calc(:), nb14_calc_list(:,:,:)

    cell_pair       => domain%cell_pairlist1
    natom           => domain%num_atom

    table_ene       => enefunc%table%table_ene
    table_grad      => enefunc%table%table_grad
    density         => enefunc%table%density
    cutoff          => enefunc%cutoffdist
    nb14_lj12       => enefunc%nb14_lj12
    nb14_lj6        => enefunc%nb14_lj6
    num_nb14_calc   => enefunc%num_nb14_calc
    nb14_calc_list  => enefunc%nb14_calc_list

    cutoff2         =  cutoff * cutoff
    ncell_local     =  domain%num_cell_local


    !$omp parallel default(shared)                                             &
    !$omp private(id, i, j, k, ij, ix, iy, m, ini_nb14, fin_nb14, num_nb14,    &
    !$omp         dij, rij2, L, R, term_lj12, term_lj6, term_elec, grad_coef,  &
    !$omp         work, table, lj12, lj6, qq_scale, lj_scale, cc, inv_r12,     &
    !$omp         inv_r121, inv_r123, inv_r126, inv_r1212, iatmcls, jatmcls,   &
    !$omp         iqtmp, jqtmp, viri, evdw_temp, elec_temp)
    !
#ifdef OMP
    id = omp_get_thread_num()
#else
    id = 0
#endif

    ! calculate energy and gradient
    !
    do ij = id+1, ncell_local, nthread

      evdw_temp = 0.0_wp
      elec_temp = 0.0_wp
      viri(1:3) = 0.0_wp

      do k = 1, num_nb14_calc(ij)

        i  = nb14_calc_list(1,k,ij)
        j  = nb14_calc_list(2,k,ij)

        iatmcls = atmcls(i)
        jatmcls = atmcls(j)

        ! compute distance
        !
        dij(1) = coord(1,i,1) - coord(1,j,1)
        dij(2) = coord(2,i,1) - coord(2,j,1)
        dij(3) = coord(3,i,1) - coord(3,j,1)
        rij2     = dij(1)*dij(1) + dij(2)*dij(2) + dij(3)*dij(3)

        iqtmp  = coord(4,i,1)
        jqtmp  = coord(4,j,1)

        qq_scale = enefunc%nb14_qq_scale(k,ij)
        lj_scale = enefunc%nb14_lj_scale(k,ij)
        inv_r12  = 1.0_wp / rij2
        inv_r121 = sqrt(inv_r12)
        inv_r123 = inv_r12 * inv_r121
        inv_r126 = inv_r123 * inv_r123
        inv_r1212 = inv_r126 * inv_r126

        ! energy and gradient
        !
        rij2  = cutoff2*density/rij2
        L     = int(rij2)
        R     = rij2 - L
        lj6   = nb14_lj6 (iatmcls,jatmcls)
        lj12  = nb14_lj12(iatmcls,jatmcls)
        cc    = iqtmp * jqtmp * qq_scale

        term_lj12   = inv_r1212
        term_lj6    = inv_r126
        term_elec   = table_ene(L) + R*(table_ene(L+1)-table_ene(L))
        evdw_temp   = evdw_temp  + (term_lj12*lj12 - term_lj6*lj6)*lj_scale
        elec_temp   = elec_temp  + cc*term_elec

        term_lj12   = -12.0_wp * inv_r1212 * inv_r12
        term_lj6    = -6.0_wp * inv_r126 * inv_r12
        term_elec   = table_grad(L) + R*(table_grad(L+1)-table_grad(L))
        grad_coef   = (term_lj12*lj12 - term_lj6*lj6)*lj_scale + cc*term_elec

        work(1) = grad_coef*dij(1)
        work(2) = grad_coef*dij(2)
        work(3) = grad_coef*dij(3)
        viri(1) = viri(1) + dij(1)*work(1)
        viri(2) = viri(2) + dij(2)*work(2)
        viri(3) = viri(3) + dij(3)*work(3)

        force(1,i,1,id+1) = force(1,i,1,id+1) - work(1)
        force(2,i,1,id+1) = force(2,i,1,id+1) - work(2)
        force(3,i,1,id+1) = force(3,i,1,id+1) - work(3)
        force(1,j,1,id+1) = force(1,j,1,id+1) + work(1)
        force(2,j,1,id+1) = force(2,j,1,id+1) + work(2)
        force(3,j,1,id+1) = force(3,j,1,id+1) + work(3)

      end do

      virial(1,1,id+1) = virial(1,1,id+1) - viri(1)
      virial(2,2,id+1) = virial(2,2,id+1) - viri(2)
      virial(3,3,id+1) = virial(3,3,id+1) - viri(3)
      evdw(id+1)  = evdw(id+1) + evdw_temp
      eelec(id+1) = eelec(id+1) + elec_temp

    end do

    !$omp end parallel

    return

  end subroutine compute_energy_nonbond14_notable_gro_amber_fugaku

  !======1=========2=========3=========4=========5=========6=========7=========8
  !
  !  Subroutine    compute_energy_nonbond14_notable_gro_amber_gpu
  !> @brief        calculate nonbonded14 energy with PME and lookup table
  !!               (linear, intel kernel)
  !  @authors      JJ
  !! @param[in]    domain  : domain information
  !! @param[in]    enefunc : potential energy functions
  !! @param[inout] force   : forces for each cell
  !! @param[inout] eelec   : electrostatic energy of target systems
  !! @param[inout] evdw    : van der Waals energy of target systems
  !
  !======1=========2=========3=========4=========5=========6=========7=========8

  subroutine compute_energy_nonbond14_notable_gro_amber_gpu(domain, enefunc, &
                                    atmcls, coord, force, virial, eelec, evdw)

    ! formal arguments
    type(s_domain),  target, intent(in)    :: domain
    type(s_enefunc), target, intent(in)    :: enefunc
    integer,                 intent(in)    :: atmcls(:)
    real(wp),                intent(in)    :: coord(:,:,:)
    real(wp),                intent(inout) :: force(:,:,:,:)
    real(dp),                intent(inout) :: virial(:,:,:)
    real(dp),                intent(inout) :: eelec(nthread)
    real(dp),                intent(inout) :: evdw(nthread)

    ! local variables
    real(wp)                 :: dij(3), rij2
    real(wp)                 :: R, table(6)
    real(wp)                 :: term_lj12, term_lj6, term_elec
    real(wp)                 :: cutoff2, grad_coef, lj12, lj6
    real(wp)                 :: work(3), viri(3)
    real(wp)                 :: lj_scale, qq_scale, cc, iqtmp, jqtmp
    real(wp)                 :: inv_r12, inv_r121, inv_r123, inv_r126, inv_r1212
    real(wp)                 :: elec_temp, evdw_temp
    integer                  :: i, ix, iy, j, k, ij, m, L, icel, jcel
    integer                  :: iatmcls, jatmcls
    integer                  :: num_nb14, ini_nb14, fin_nb14, num_atom
    integer                  :: ncell_local, id, omp_get_thread_num

    real(wp),        pointer :: system_size(:)
    real(wp),        pointer :: nb14_lj12(:,:), nb14_lj6(:,:)
    real(wp),        pointer :: table_ene(:), table_grad(:)
    real(wp),        pointer :: density, cutoff
    integer,         pointer :: natom(:), start_atom(:)
    integer(int2),   pointer :: cell_pair(:,:)
    integer,         pointer :: num_nb14_calc(:), nb14_calc_list(:,:,:)
    integer(1),      pointer :: cell_move(:,:,:)

    cell_pair       => domain%cell_pairlist1
    natom           => domain%num_atom
    start_atom      => domain%start_atom
    system_size     => domain%system_size
    cell_move       => domain%cell_move

    table_ene       => enefunc%table%table_ene
    table_grad      => enefunc%table%table_grad
    density         => enefunc%table%density
    cutoff          => enefunc%cutoffdist
    nb14_lj12       => enefunc%nb14_lj12
    nb14_lj6        => enefunc%nb14_lj6
    num_nb14_calc   => enefunc%num_nb14_calc
    nb14_calc_list  => enefunc%nb14_calc_list

    cutoff2         =  cutoff * cutoff
    ncell_local     =  domain%num_cell_local
    num_atom        =  domain%num_atom_domain

    !$omp parallel default(shared)                                             &
    !$omp private(id, i, j, k, ij, ix, iy, m, ini_nb14, fin_nb14, num_nb14,    &
    !$omp         dij, rij2, L, R, term_lj12, term_lj6, term_elec, grad_coef,  &
    !$omp         work, table, lj12, lj6, qq_scale, lj_scale, cc, inv_r12,     &
    !$omp         inv_r121, inv_r123, inv_r126, inv_r1212, iatmcls, jatmcls,   &
    !$omp         icel, jcel, iqtmp, jqtmp, viri, evdw_temp, elec_temp)
    !
#ifdef OMP
    id = omp_get_thread_num()
#else
    id = 0
#endif

    ! calculate energy and gradient
    !
    do ij = id+1, ncell_local, nthread

      evdw_temp = 0.0_wp
      elec_temp = 0.0_wp
      viri(1:3) = 0.0_wp

      do k = 1, num_nb14_calc(ij)

        icel  = nb14_calc_list(1,k,ij)
        jcel  = nb14_calc_list(2,k,ij)
        ix    = nb14_calc_list(3,k,ij)
        iy    = nb14_calc_list(4,k,ij)
        i     = start_atom(icel) + ix
        j     = start_atom(jcel) + iy

        iatmcls = atmcls(i)
        jatmcls = atmcls(j)

        ! compute distance
        !
        dij(1) = coord(           i,1,1) - coord(           j,1,1)
        dij(2) = coord(  num_atom+i,1,1) - coord(  num_atom+j,1,1)
        dij(3) = coord(2*num_atom+i,1,1) - coord(2*num_atom+j,1,1)
        dij(1) = dij(1) + cell_move(1,jcel,icel)*system_size(1)
        dij(2) = dij(2) + cell_move(2,jcel,icel)*system_size(2)
        dij(3) = dij(3) + cell_move(3,jcel,icel)*system_size(3)
        rij2     = dij(1)*dij(1) + dij(2)*dij(2) + dij(3)*dij(3)

        iqtmp  = coord(3*num_atom+i,1,1)
        jqtmp  = coord(3*num_atom+j,1,1)
        qq_scale = enefunc%nb14_qq_scale(k,ij)
        lj_scale = enefunc%nb14_lj_scale(k,ij)
        inv_r12  = 1.0_wp / rij2
        inv_r121 = sqrt(inv_r12)
        inv_r123 = inv_r12 * inv_r121
        inv_r126 = inv_r123 * inv_r123
        inv_r1212 = inv_r126 * inv_r126

        ! energy and gradient
        !
        rij2  = cutoff2*density/rij2
        L     = int(rij2)
        R     = rij2 - L
        lj6   = nb14_lj6 (iatmcls,jatmcls)
        lj12  = nb14_lj12(iatmcls,jatmcls)
        cc    = iqtmp * jqtmp * qq_scale

        term_lj12   = inv_r1212
        term_lj6    = inv_r126
        term_elec   = table_ene(L) + R*(table_ene(L+1)-table_ene(L))
        evdw_temp   = evdw_temp  + (term_lj12*lj12 - term_lj6*lj6)*lj_scale
        elec_temp   = elec_temp  + cc*term_elec

        term_lj12   = -12.0_wp * inv_r1212 * inv_r12
        term_lj6    = -6.0_wp * inv_r126 * inv_r12
        term_elec   = table_grad(L) + R*(table_grad(L+1)-table_grad(L))
        grad_coef   = (term_lj12*lj12 - term_lj6*lj6)*lj_scale + cc*term_elec

        work(1) = grad_coef*dij(1)
        work(2) = grad_coef*dij(2)
        work(3) = grad_coef*dij(3)
        viri(1) = viri(1) + dij(1)*work(1)
        viri(2) = viri(2) + dij(2)*work(2)
        viri(3) = viri(3) + dij(3)*work(3)

        force(1,ix,icel,id+1) = force(1,ix,icel,id+1) - work(1)
        force(2,ix,icel,id+1) = force(2,ix,icel,id+1) - work(2)
        force(3,ix,icel,id+1) = force(3,ix,icel,id+1) - work(3)
        force(1,iy,jcel,id+1) = force(1,iy,jcel,id+1) + work(1)
        force(2,iy,jcel,id+1) = force(2,iy,jcel,id+1) + work(2)
        force(3,iy,jcel,id+1) = force(3,iy,jcel,id+1) + work(3)

      end do

      virial(1,1,id+1) = virial(1,1,id+1) - viri(1)
      virial(2,2,id+1) = virial(2,2,id+1) - viri(2)
      virial(3,3,id+1) = virial(3,3,id+1) - viri(3)
      evdw(id+1)  = evdw(id+1) + evdw_temp
      eelec(id+1) = eelec(id+1) + elec_temp

    end do

    !$omp end parallel

    return

  end subroutine compute_energy_nonbond14_notable_gro_amber_gpu

  !======1=========2=========3=========4=========5=========6=========7=========8
  !
  !  Subroutine    compute_energy_nonbond14_notable_gro_amber_generic
  !> @brief        calculate nonbonded14 energy with PME and lookup table
  !!               (linear)
  !  @authors      JJ
  !! @param[in]    domain  : domain information
  !! @param[in]    enefunc : potential energy functions
  !! @param[inout] force   : forces for each cell
  !! @param[inout] eelec   : electrostatic energy of target systems
  !! @param[inout] evdw    : van der Waals energy of target systems
  !
  !======1=========2=========3=========4=========5=========6=========7=========8

  subroutine compute_energy_nonbond14_notable_gro_amber_generic(domain,   &
                                  enefunc, coord, force, virial, eelec, evdw)

    ! formal arguments
    type(s_domain),  target, intent(in)    :: domain
    type(s_enefunc), target, intent(in)    :: enefunc
    real(wp),                intent(in)    :: coord(:,:,:)
    real(wp),                intent(inout) :: force(:,:,:,:)
    real(dp),                intent(inout) :: virial(:,:,:)
    real(dp),                intent(inout) :: eelec(nthread)
    real(dp),                intent(inout) :: evdw(nthread)

    ! local variables
    real(wp)                 :: dij(3), rij2
    real(wp)                 :: R, table(6)
    real(wp)                 :: term_lj12, term_lj6, term_elec
    real(wp)                 :: cutoff2, grad_coef, lj12, lj6
    real(wp)                 :: work(3), viri(3)
    real(wp)                 :: lj_scale, qq_scale, cc
    real(wp)                 :: inv_r12, inv_r121, inv_r123, inv_r126, inv_r1212
    real(wp)                 :: elec_temp, evdw_temp
    integer                  :: i, ix, iy, j, k, ij, m, L
    integer                  :: iatmcls, jatmcls
    integer                  :: num_nb14, ini_nb14, fin_nb14
    integer                  :: ncell_local, id, omp_get_thread_num

    real(wp),        pointer :: charge(:,:), system_size(:)
    real(wp),        pointer :: nb14_lj12(:,:), nb14_lj6(:,:)
    real(wp),        pointer :: table_ene(:), table_grad(:)
    real(wp),        pointer :: density, cutoff
    integer,         pointer :: atmcls(:,:), natom(:)
    integer(int2),   pointer :: cell_pair(:,:)
    integer,         pointer :: num_nb14_calc(:), nb14_calc_list(:,:,:)
    integer(1),      pointer :: cell_move(:,:,:)

    charge          => domain%charge
    cell_pair       => domain%cell_pairlist1
    atmcls          => domain%atom_cls_no
    natom           => domain%num_atom
    system_size     => domain%system_size
    cell_move       => domain%cell_move

    table_ene       => enefunc%table%table_ene
    table_grad      => enefunc%table%table_grad
    density         => enefunc%table%density
    cutoff          => enefunc%cutoffdist
    nb14_lj12       => enefunc%nb14_lj12
    nb14_lj6        => enefunc%nb14_lj6
    num_nb14_calc   => enefunc%num_nb14_calc
    nb14_calc_list  => enefunc%nb14_calc_list

    cutoff2         =  cutoff * cutoff
    ncell_local     =  domain%num_cell_local


    !$omp parallel default(shared)                                             &
    !$omp private(id, i, j, k, ij, ix, iy, m, ini_nb14, fin_nb14, num_nb14,    &
    !$omp         dij, rij2, L, R, term_lj12, term_lj6, term_elec, grad_coef,  &
    !$omp         work, table, lj12, lj6, qq_scale, lj_scale, cc, inv_r12,     &
    !$omp         inv_r121, inv_r123, inv_r126, inv_r1212, iatmcls, jatmcls,   &
    !$omp         viri, evdw_temp, elec_temp)
    !
#ifdef OMP
    id = omp_get_thread_num()
#else
    id = 0
#endif

    ! calculate energy and gradient
    !
    do ij = id+1, ncell_local, nthread

      evdw_temp = 0.0_wp
      elec_temp = 0.0_wp
      viri(1:3) = 0.0_wp

      do k = 1, num_nb14_calc(ij)

        i  = nb14_calc_list(1,k,ij)
        j  = nb14_calc_list(2,k,ij)
        ix = nb14_calc_list(3,k,ij)
        iy = nb14_calc_list(4,k,ij)

        iatmcls = atmcls(ix,i)
        jatmcls = atmcls(iy,j)

        ! compute distance
        !
        dij(1) = coord(ix,1,i) - coord(iy,1,j)
        dij(2) = coord(ix,2,i) - coord(iy,2,j)
        dij(3) = coord(ix,3,i) - coord(iy,3,j)
        dij(1) = dij(1) + real(cell_move(1,j,i),wp)*system_size(1)
        dij(2) = dij(2) + real(cell_move(2,j,i),wp)*system_size(2)
        dij(3) = dij(3) + real(cell_move(3,j,i),wp)*system_size(3)
        rij2     = dij(1)*dij(1) + dij(2)*dij(2) + dij(3)*dij(3)
        qq_scale = enefunc%nb14_qq_scale(k,ij)
        lj_scale = enefunc%nb14_lj_scale(k,ij)
        inv_r12  = 1.0_wp / rij2
        inv_r121 = sqrt(inv_r12)
        inv_r123 = inv_r12 * inv_r121
        inv_r126 = inv_r123 * inv_r123
        inv_r1212 = inv_r126 * inv_r126

        ! energy and gradient
        !
        rij2  = cutoff2*density/rij2
        L     = int(rij2)
        R     = rij2 - L
        lj6   = nb14_lj6 (iatmcls,jatmcls)
        lj12  = nb14_lj12(iatmcls,jatmcls)
        cc    = charge(ix,i)*charge(iy,j)*qq_scale

        term_lj12   = inv_r1212 
        term_lj6    = inv_r126
        term_elec   = table_ene(L) + R*(table_ene(L+1)-table_ene(L))
        evdw_temp   = evdw_temp  + (term_lj12*lj12 - term_lj6*lj6)*lj_scale
        elec_temp   = elec_temp  + cc*term_elec

        term_lj12   = -12.0_wp * inv_r1212 * inv_r12
        term_lj6    = -6.0_wp * inv_r126 * inv_r12
        term_elec   = table_grad(L) + R*(table_grad(L+1)-table_grad(L))
        grad_coef   = (term_lj12*lj12 - term_lj6*lj6)*lj_scale + cc*term_elec

        work(1) = grad_coef*dij(1)
        work(2) = grad_coef*dij(2)
        work(3) = grad_coef*dij(3)
        viri(1) = viri(1) + dij(1)*work(1)
        viri(2) = viri(2) + dij(2)*work(2)
        viri(3) = viri(3) + dij(3)*work(3)

        force(1,ix,i,id+1) = force(1,ix,i,id+1) - work(1)
        force(2,ix,i,id+1) = force(2,ix,i,id+1) - work(2)
        force(3,ix,i,id+1) = force(3,ix,i,id+1) - work(3)
        force(1,iy,j,id+1) = force(1,iy,j,id+1) + work(1)
        force(2,iy,j,id+1) = force(2,iy,j,id+1) + work(2)
        force(3,iy,j,id+1) = force(3,iy,j,id+1) + work(3)

      end do

      virial(1,1,id+1) = virial(1,1,id+1) - viri(1)
      virial(2,2,id+1) = virial(2,2,id+1) - viri(2)
      virial(3,3,id+1) = virial(3,3,id+1) - viri(3)
      evdw(id+1)  = evdw(id+1) + evdw_temp
      eelec(id+1) = eelec(id+1) + elec_temp
 
    end do

    !$omp end parallel

    return

  end subroutine compute_energy_nonbond14_notable_gro_amber_generic

  !======1=========2=========3=========4=========5=========6=========7=========8
  !
  !  Subroutine    compute_energy_nonbond14_notable_gro_amber_check
  !> @brief        calculate nonbonded14 energy without lookup table of vdw
  !!               (linear)
  !  @authors      JJ, CK
  !! @param[in]    domain  : domain information
  !! @param[in]    enefunc : potential energy functions
  !! @param[inout] force   : forces for each cell
  !! @param[inout] eelec   : electrostatic energy of target systems
  !! @param[inout] evdw    : van der Waals energy of target systems
  !
  !======1=========2=========3=========4=========5=========6=========7=========8

  subroutine compute_energy_nonbond14_notable_gro_amber_check (domain, enefunc,&
                                             coord, force, virial, eelec, evdw)

    ! formal arguments
    type(s_domain),  target, intent(in)    :: domain
    type(s_enefunc), target, intent(in)    :: enefunc
    real(wp),                intent(in)    :: coord(:,:,:)
    real(wp),                intent(inout) :: force(:,:,:,:)
    real(dp),                intent(inout) :: virial(:,:,:)
    real(dp),                intent(inout) :: eelec(nthread)
    real(dp),                intent(inout) :: evdw(nthread)

    ! local variables
    real(wp)                 :: dij(3), rij2
    real(wp)                 :: R, table(6)
    real(wp)                 :: term_lj12, term_lj6, term_elec
    real(wp)                 :: cutoff2, grad_coef, lj12, lj6
    real(wp)                 :: work(3), viri(3)
    real(wp)                 :: lj_scale, qq_scale, cc
    real(wp)                 :: inv_r12, inv_r121, inv_r123, inv_r126, inv_r1212
    real(wp)                 :: minimum_contact
    real(wp)                 :: evdw_temp, elec_temp
    integer                  :: i, ix, iy, j, k, ij, m, L
    integer                  :: iatmcls, jatmcls
    integer                  :: num_nb14, ini_nb14, fin_nb14
    integer                  :: ncell_local, id, omp_get_thread_num

    real(wp),        pointer :: charge(:,:), system_size(:)
    real(wp),        pointer :: nb14_lj12(:,:), nb14_lj6(:,:)
    real(wp),        pointer :: table_ene(:), table_grad(:)
    real(wp),        pointer :: density, cutoff
    integer,         pointer :: atmcls(:,:), natom(:)
    integer(int2),   pointer :: cell_pair(:,:)
    integer,         pointer :: num_nb14_calc(:), nb14_calc_list(:,:,:)
    integer(1),      pointer :: cell_move(:,:,:)

    charge          => domain%charge
    cell_pair       => domain%cell_pairlist1
    atmcls          => domain%atom_cls_no
    natom           => domain%num_atom
    system_size     => domain%system_size
    cell_move       => domain%cell_move

    table_ene       => enefunc%table%table_ene
    table_grad      => enefunc%table%table_grad
    density         => enefunc%table%density
    cutoff          => enefunc%cutoffdist
    nb14_lj12       => enefunc%nb14_lj12
    nb14_lj6        => enefunc%nb14_lj6
    num_nb14_calc   => enefunc%num_nb14_calc
    nb14_calc_list  => enefunc%nb14_calc_list

    cutoff2         =  cutoff * cutoff
    ncell_local     =  domain%num_cell_local
    minimum_contact = enefunc%minimum_contact


    !$omp parallel default(shared)                                             &
    !$omp private(id, i, j, k, ij, ix, iy, m, ini_nb14, fin_nb14, num_nb14,    &
    !$omp         dij, rij2, L, R, term_lj12, term_lj6, term_elec, grad_coef,  &
    !$omp         work, table, lj12, lj6, qq_scale, lj_scale, cc, inv_r12,     &
    !$omp         inv_r121, inv_r123, inv_r126, inv_r1212, iatmcls, jatmcls,   &
    !$omp         viri, evdw_temp, elec_temp)
    !
#ifdef OMP
    id = omp_get_thread_num()
#else
    id = 0
#endif

    ! calculate energy and gradient
    !
    do ij = id+1, ncell_local, nthread

      evdw_temp = 0.0_wp
      elec_temp = 0.0_wp
      viri(1:3) = 0.0_wp

      do k = 1, num_nb14_calc(ij)

        i  = nb14_calc_list(1,k,ij)
        j  = nb14_calc_list(2,k,ij)
        ix = nb14_calc_list(3,k,ij)
        iy = nb14_calc_list(4,k,ij)

        iatmcls = atmcls(ix,i)
        jatmcls = atmcls(iy,j)

        ! compute distance
        !
        dij(1:3) = coord(ix,1:3,i) - coord(iy,1:3,j)
        dij(1:3) = dij(1:3) + real(cell_move(1:3,j,i),wp)*system_size(1:3)
        rij2     = dij(1)*dij(1) + dij(2)*dij(2) + dij(3)*dij(3)
        rij2     = max(rij2, minimum_contact)
        qq_scale = enefunc%nb14_qq_scale(k,ij)
        lj_scale = enefunc%nb14_lj_scale(k,ij)
        inv_r12  = 1.0_wp / rij2
        inv_r121 = sqrt(inv_r12)
        inv_r123 = inv_r12 * inv_r121
        inv_r126 = inv_r123 * inv_r123
        inv_r1212 = inv_r126 * inv_r126

        ! energy and gradient
        !
        rij2  = cutoff2*density/rij2
        L     = int(rij2)
        R     = rij2 - L
        lj6   = nb14_lj6 (iatmcls,jatmcls)
        lj12  = nb14_lj12(iatmcls,jatmcls)
        cc    = charge(ix,i)*charge(iy,j)*qq_scale

        term_lj12   = inv_r1212 
        term_lj6    = inv_r126
        term_elec   = table_ene(L) + R*(table_ene(L+1)-table_ene(L))
        evdw_temp   = evdw_temp  + (term_lj12*lj12 - term_lj6*lj6)*lj_scale
        elec_temp   = elec_temp  + cc*term_elec

        term_lj12   = -12.0_wp * inv_r1212 * inv_r12
        term_lj6    = -6.0_wp * inv_r126 * inv_r12
        term_elec   = table_grad(L) + R*(table_grad(L+1)-table_grad(L))
        grad_coef   = (term_lj12*lj12 - term_lj6*lj6)*lj_scale + cc*term_elec

        work(1:3) = grad_coef*dij(1:3)
        viri(1:3) = viri(1:3) + dij(1:3)*work(1:3)

        force(1:3,ix,i,id+1) = force(1:3,ix,i,id+1) - work(1:3)
        force(1:3,iy,j,id+1) = force(1:3,iy,j,id+1) + work(1:3)

      end do

      virial(1,1,id+1) = virial(1,1,id+1) - viri(1)
      virial(2,2,id+1) = virial(2,2,id+1) - viri(2)
      virial(3,3,id+1) = virial(3,3,id+1) - viri(3)
      evdw(id+1)  = evdw(id+1) + evdw_temp
      eelec(id+1) = eelec(id+1) + elec_temp
 
    end do

    !$omp end parallel

    return

  end subroutine compute_energy_nonbond14_notable_gro_amber_check


end module sp_energy_14_notable_mod
