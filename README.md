# OASIS Explorer 

Simple Matlab GUI to explore various OASIS calcium imaging deconvolution settings and parameters. 
File should be a cleaned calcium imaging dataset (use PRISM - https://github.com/bastijnvandenboom/PRISM), or a CNMF file.

# what to explore
OASIS is a fast and efficient calcium imaging deconvolution algorithm. It allows to denoise and deconvolve temporal traces. However, manual curation of the settings is waranted to avoid false-positive and false-negative events. Use the overlap between C_raw (DF/F), C (denoised, and S (deconvolved) to make sure false-positive and false-negative events are rare. Importantly, the residual plot (C_raw - C) shows how well denoising worked. If you still see calcium imaging-like events, you probably have a lot of false-negative events. 

# how to use it

1. Data
  
   load updated_imaging.mat file

2. Cells/Frames to deconvolve

   Select number of cells (idx or range) and number of frames. The more cells/frames the longer OASIS will run

3. OASIS/deconvolveCa parameters

   try various OASIS parameters. Start with default settings. Hit Run OASIS

4. Results navigator

   Use <<' Prev and Next '>> to plot different cells. If you rerun OASIS with different frame lengths, you can find those runs in the dropdown list

FIGURE 1: Overview of OASIS explorer
![oasis_explorer](https://github.com/bastijnvandenboom/oasis_explorer/blob/b5f68ab8958ee78ed00271b48bad056424fd9aff/oasis_deconvolution_explorer.png)
